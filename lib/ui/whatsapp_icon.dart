import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// WhatsApp green, for buttons that open WhatsApp.
const kWhatsAppGreen = Color(0xFF25D366);

/// The WhatsApp mark drawn from icons (a speech bubble round a phone), white, for a WhatsApp-green button.
class WhatsAppIcon extends StatelessWidget {
  const WhatsAppIcon({super.key, this.size = 30, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          Transform.flip(flipX: true, child: Icon(LucideIcons.messageCircle, size: size, color: color)),
          Icon(LucideIcons.phone, size: size * .42, color: color),
        ]),
      );
}
