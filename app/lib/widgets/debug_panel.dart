import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/telemetry_service.dart';
import 'premium_widgets.dart';

class DebugPanel extends StatelessWidget {
  const DebugPanel({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const DebugPanel(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (context, scrollController) {
        return GlassCard(
          borderRadius: 32,
          blur: 40,
          opacity: 0.2,
          child: Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Advanced Telemetry',
                      style: GoogleFonts.outfit(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(height: 32, color: Colors.white10),
                Expanded(
                  child: FutureBuilder<List<TransferSession>>(
                    future: TelemetryService().getHistory(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final history = snapshot.data!;
                      if (history.isEmpty) {
                        return Center(
                          child: Text(
                            'No sessions recorded yet.',
                            style: TextStyle(color: Colors.white30),
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final session = history[index];
                          return _buildSessionCard(session);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSessionCard(TransferSession session) {
    final color = session.isSuccess ? const Color(0xFF03DAC6) : Colors.redAccent;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ID: ${session.id.substring(0, 8)}...',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w600, color: Colors.white70),
              ),
              Icon(
                session.isSuccess ? Icons.check_circle : Icons.error,
                color: color,
                size: 16,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _buildMetric('Route', session.route ?? 'N/A', Icons.alt_route),
              _buildMetric('Carrier', session.carrier ?? 'N/A', Icons.cell_tower),
              _buildMetric('Latency', '${session.connectTimeMs ?? "?"}ms', Icons.timer),
              _buildMetric('Speed', '${session.speedMbps?.toStringAsFixed(2) ?? "?"} Mbps', Icons.speed),
            ],
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1, end: 0);
  }

  Widget _buildMetric(String label, String value, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 10, color: Colors.white30),
            const SizedBox(width: 4),
            Text(label.toUpperCase(), style: const TextStyle(fontSize: 9, color: Colors.white30, fontWeight: FontWeight.bold)),
          ],
        ),
        Text(value, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
