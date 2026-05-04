import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../config.dart';

class RouteIndicator extends StatelessWidget {
  final ValueNotifier<String> routeNotifier;
  
  const RouteIndicator({
    super.key,
    required this.routeNotifier,
  });

  @override
  Widget build(BuildContext context) {
    if (!FEATURES.routeIndicator) return const SizedBox.shrink();

    return ValueListenableBuilder<String>(
      valueListenable: routeNotifier,
      builder: (context, route, _) {
        IconData icon;
        Color color;
        
        switch (route) {
          case 'Encrypted P2P':
            icon = Icons.bolt_rounded;
            color = const Color(0xFFBB86FC);
            break;
          case 'Relay':
            icon = Icons.alt_route_rounded;
            color = const Color(0xFF03DAC6);
            break;
          case 'QUIC':
            icon = Icons.speed_rounded;
            color = Colors.orangeAccent;
            break;
          case 'TCP':
            icon = Icons.lan_rounded;
            color = Colors.blueAccent;
            break;
          default:
            icon = Icons.sync_rounded;
            color = Colors.white24;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.2), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color)
                  .animate(key: ValueKey(route))
                  .scale(duration: 400.ms, curve: Curves.easeOutBack)
                  .shimmer(delay: 2.seconds, duration: 2.seconds),
              const SizedBox(width: 8),
              Text(
                route.toUpperCase(),
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: color.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ).animate(key: ValueKey(route)).fadeIn().slideX(begin: 0.1, end: 0);
      },
    );
  }
}
