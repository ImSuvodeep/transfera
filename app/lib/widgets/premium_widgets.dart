import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lottie/lottie.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.blur = 20.0,
    this.opacity = 0.1,
    this.borderRadius = 24.0,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(opacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor ?? Colors.white.withOpacity(0.1),
              width: 1.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class AnimatedMeshGradient extends StatelessWidget {
  const AnimatedMeshGradient({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: const Color(0xFF050505),
          ),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0.4,
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.8, -0.6),
                  radius: 1.2,
                  colors: [
                    Color(0xFF6200EE),
                    Colors.transparent,
                  ],
                ),
              ),
            ).animate(onPlay: (controller) => controller.repeat(reverse: true))
             .move(begin: const Offset(-20, -20), end: const Offset(20, 20), duration: 8.seconds, curve: Curves.easeInOut),
          ),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0.3,
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.8, 0.6),
                  radius: 1.2,
                  colors: [
                    Color(0xFF03DAC6),
                    Colors.transparent,
                  ],
                ),
              ),
            ).animate(onPlay: (controller) => controller.repeat(reverse: true))
             .move(begin: const Offset(30, 30), end: const Offset(-30, -30), duration: 10.seconds, curve: Curves.easeInOut),
          ),
        ),
      ],
    );
  }
}

class PremiumSuccessPopup extends StatelessWidget {
  final String fileName;
  final VoidCallback onOpen;
  final Duration? transferDuration;

  const PremiumSuccessPopup({
    super.key,
    required this.fileName,
    required this.onOpen,
    this.transferDuration,
  });

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GlassCard(
        blur: 30,
        opacity: 0.15,
        borderRadius: 32,
        child: Container(
          width: 320,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF00E676),
                  size: 64,
                ),
              ).animate()
               .scale(duration: 600.ms, curve: Curves.easeOutBack)
               .shimmer(delay: 800.ms, duration: 1200.ms),
              const SizedBox(height: 24),
              const Text(
                'Received Successfully',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ).animate().fadeIn(delay: 200.ms).moveY(begin: 10, end: 0),
              const SizedBox(height: 8),
              Text(
                fileName,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ).animate().fadeIn(delay: 400.ms),
              if (transferDuration != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer_outlined, size: 16, color: Color(0xFF03DAC6)),
                      const SizedBox(width: 8),
                      Text(
                        _formatDuration(transferDuration!),
                        style: const TextStyle(
                          color: Color(0xFF03DAC6),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 500.ms).moveY(begin: 10, end: 0),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: onOpen,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 60),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text('Open File'),
              ).animate().fadeIn(delay: 600.ms).scale(begin: const Offset(0.9, 0.9)),
            ],
          ),
        ),
      ).animate().moveY(begin: 100, end: 0, curve: Curves.easeOutQuart, duration: 800.ms).fadeIn(),
    );
  }
}
