package com.onelocal.vinii_pos

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Printers plugged into the phone (USB through an OTG cable) or paired over Bluetooth (founder, 4 Nov 2026): the app sends the
// receipt's ESC/POS or the labels' TSPL bytes straight to the printer, with no printer maker's app and no print dialog.
// Channel "onelocal/printers": list → [{kind, address, name}], write {address, bytes}. A USB printer's address is
// usb:<vendor>:<product> (hex); a Bluetooth printer's is its MAC. Bluetooth printers must be paired in Android's settings first.
class LocalPrinters(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "onelocal/printers")
    private var waiting: (() -> Unit)? = null
    private var refused: (() -> Unit)? = null

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> withBluetooth({ result.success(usbPrinters() + bluetoothPrinters()) }, { result.success(usbPrinters()) })
            "write" -> {
                val address = call.argument<String>("address") ?: ""
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                val run = {
                    Thread {
                        try {
                            if (address.startsWith("usb:")) writeUsb(address, bytes) else writeBluetooth(address, bytes)
                            activity.runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            activity.runOnUiThread { result.error("print_failed", e.message ?: "The printer did not answer.", null) }
                        }
                    }.start()
                }
                if (address.startsWith("usb:")) run()
                else withBluetooth(run) { result.error("bluetooth_permission", "Allow Nearby devices for OneLocal to print over Bluetooth.", null) }
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- Bluetooth permission (Android 12+: Nearby devices)

    private fun withBluetooth(granted: () -> Unit, denied: () -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        ) return granted()
        waiting = granted
        refused = denied
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_BT)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_BT) return
        val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val next = if (ok) waiting else refused
        waiting = null
        refused = null
        next?.invoke()
    }

    // ---------------------------------------------------------------- USB (OTG)

    private val usb get() = activity.getSystemService(Context.USB_SERVICE) as UsbManager

    /** The USB end a printer takes data on: a bulk OUT endpoint, on the printer-class interface when there is one. */
    private fun printerEnd(d: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        val found = mutableListOf<Pair<UsbInterface, UsbEndpoint>>()
        for (i in 0 until d.interfaceCount) {
            val itf = d.getInterface(i)
            for (e in 0 until itf.endpointCount) {
                val ep = itf.getEndpoint(e)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) found.add(itf to ep)
            }
        }
        return found.firstOrNull { it.first.interfaceClass == UsbConstants.USB_CLASS_PRINTER } ?: found.firstOrNull()
    }

    private fun address(d: UsbDevice) = "usb:%04x:%04x".format(d.vendorId, d.productId)

    private fun usbPrinters(): List<Map<String, String>> = usb.deviceList.values.filter { printerEnd(it) != null }.map { d ->
        val name = listOfNotNull(d.manufacturerName, d.productName).joinToString(" ").trim()
        mapOf("kind" to "usb", "address" to address(d), "name" to name.ifEmpty { "USB printer" })
    }

    private fun writeUsb(addr: String, bytes: ByteArray) {
        val d = usb.deviceList.values.firstOrNull { address(it) == addr }
            ?: throw Exception("The USB printer is not plugged in. Check the OTG cable and that the printer is on.")
        if (!usb.hasPermission(d) && !askUsb(d)) throw Exception("Allow OneLocal to use the USB printer, then try again.")
        val (itf, ep) = printerEnd(d) ?: throw Exception("This USB device is not a printer.")
        val conn = usb.openDevice(d) ?: throw Exception("Could not open the USB printer.")
        try {
            if (!conn.claimInterface(itf, true)) throw Exception("The USB printer is busy.")
            var at = 0
            while (at < bytes.size) {
                val n = minOf(CHUNK, bytes.size - at)
                val sent = conn.bulkTransfer(ep, bytes, at, n, 5000)
                if (sent <= 0) throw Exception("The USB printer stopped taking data.")
                at += sent
            }
            conn.releaseInterface(itf)
        } finally {
            conn.close()
        }
    }

    /** Asks Android for the printer (the "Allow OneLocal to access…" box) and waits up to a minute for the answer. */
    private fun askUsb(d: UsbDevice): Boolean {
        val latch = CountDownLatch(1)
        var ok = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                ok = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                latch.countDown()
            }
        }
        val filter = IntentFilter(ACTION_USB)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else activity.registerReceiver(receiver, filter)
        try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val intent = PendingIntent.getBroadcast(activity, 0, Intent(ACTION_USB).setPackage(activity.packageName), flags)
            usb.requestPermission(d, intent)
            latch.await(60, TimeUnit.SECONDS)
        } finally {
            activity.unregisterReceiver(receiver)
        }
        return ok
    }

    // ---------------------------------------------------------------- Bluetooth (paired printers, serial port profile)

    private val bluetooth get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    @SuppressLint("MissingPermission") // asked for in withBluetooth
    private fun bluetoothPrinters(): List<Map<String, String>> {
        val a = bluetooth ?: return emptyList()
        if (!a.isEnabled) return emptyList()
        return a.bondedDevices.map { mapOf("kind" to "bluetooth", "address" to it.address, "name" to (it.name ?: it.address)) }
    }

    @SuppressLint("MissingPermission")
    private fun writeBluetooth(mac: String, bytes: ByteArray) {
        val a = bluetooth ?: throw Exception("This phone has no Bluetooth.")
        if (!a.isEnabled) throw Exception("Turn on Bluetooth, then try again.")
        val d = a.bondedDevices.firstOrNull { it.address.equals(mac, ignoreCase = true) }
            ?: throw Exception("Pair the printer in the phone's Bluetooth settings first.")
        a.cancelDiscovery()
        val socket = d.createRfcommSocketToServiceRecord(SPP)
        try {
            socket.connect()
            socket.outputStream.write(bytes)
            socket.outputStream.flush()
            Thread.sleep(300) // let the printer take the last bytes before the link closes
        } catch (e: Exception) {
            throw Exception("Could not reach ${d.name ?: "the printer"}. Check it is on and near the phone.")
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val REQUEST_BT = 4711
        private const val CHUNK = 16384
        private const val ACTION_USB = "com.onelocal.partner.USB_PRINTER"
        private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
