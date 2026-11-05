package com.onelocal.vinii_pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// USB receipt printers (founder, 4 Nov 2026: "whenever i try to print the test print it is not connecting to any printer", a USB
// printer): Android's print screen cannot reach a USB thermal printer, so the app sends ESC/POS bytes straight down the cable.
// Channel onelocal/usb_printer: list → the USB devices that can take a print job; print {bytes} → sends them to the printer
// (asking Android's "Allow OneLocal Partner to access the USB device?" the first time). Errors: USB_NONE, USB_DENIED, USB_FAILED.
class MainActivity : FlutterActivity() {
    private val permissionAction = "com.onelocal.vinii_pos.USB_PERMISSION"
    private var localPrinters: LocalPrinters? = null // the printers picked in the store's Devices (Bluetooth, USB)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localPrinters = LocalPrinters(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "onelocal/usb_printer").setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(printers().map { (d, _) -> mapOf("name" to (d.productName ?: d.deviceName), "maker" to (d.manufacturerName ?: ""), "id" to d.deviceName) })
                "print" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) { result.error("USB_FAILED", "nothing to print", null); return@setMethodCallHandler }
                    printUsb(bytes, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        localPrinters?.onPermissionResult(requestCode, grantResults)
    }

    private val usb get() = getSystemService(Context.USB_SERVICE) as UsbManager

    /** Devices with a bulk OUT endpoint: printer-class ones first, then vendor-specific ones (many cheap thermal printers). */
    private fun printers(): List<Pair<UsbDevice, Pair<UsbInterface, UsbEndpoint>>> {
        val found = mutableListOf<Triple<Int, UsbDevice, Pair<UsbInterface, UsbEndpoint>>>()
        for (d in usb.deviceList.values) {
            for (i in 0 until d.interfaceCount) {
                val itf = d.getInterface(i)
                val rank = when (itf.interfaceClass) {
                    UsbConstants.USB_CLASS_PRINTER -> 0
                    UsbConstants.USB_CLASS_VENDOR_SPEC -> 1
                    else -> continue
                }
                for (e in 0 until itf.endpointCount) {
                    val ep = itf.getEndpoint(e)
                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) {
                        found.add(Triple(rank, d, itf to ep)); break
                    }
                }
                if (found.any { it.second == d }) break
            }
        }
        return found.sortedBy { it.first }.map { it.second to it.third }
    }

    private fun printUsb(bytes: ByteArray, result: MethodChannel.Result) {
        val target = printers().firstOrNull()
        if (target == null) { result.error("USB_NONE", "no USB printer found", null); return }
        val device = target.first
        if (usb.hasPermission(device)) { send(device, target.second, bytes, result); return }
        // first time: Android asks whether this app may use the printer
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != permissionAction) return
                try { unregisterReceiver(this) } catch (_: Exception) {}
                if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) || usb.hasPermission(device)) send(device, target.second, bytes, result)
                else result.error("USB_DENIED", "USB access was not allowed", null)
            }
        }
        val filter = IntentFilter(permissionAction)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED) else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(receiver, filter)
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(this, 0, Intent(permissionAction).setPackage(packageName), flags))
    }

    private fun send(device: UsbDevice, target: Pair<UsbInterface, UsbEndpoint>, bytes: ByteArray, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        Thread {
            val conn = usb.openDevice(device)
            if (conn == null) { main.post { result.error("USB_FAILED", "the printer could not be opened", null) }; return@Thread }
            try {
                if (!conn.claimInterface(target.first, true)) { main.post { result.error("USB_FAILED", "the printer is busy", null) }; return@Thread }
                var at = 0
                while (at < bytes.size) {
                    val n = minOf(4096, bytes.size - at)
                    val sent = conn.bulkTransfer(target.second, bytes, at, n, 5000)
                    if (sent <= 0) { main.post { result.error("USB_FAILED", "the printer stopped taking data", null) }; return@Thread }
                    at += sent
                }
                conn.releaseInterface(target.first)
                main.post { result.success(true) }
            } finally {
                conn.close()
            }
        }.start()
    }
}
