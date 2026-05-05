import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/history_service.dart';
import '../widgets/premium_widgets.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'Transfer History',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white54),
            tooltip: 'Clear history',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF1E1E2E),
                  title: const Text('Clear History',
                      style: TextStyle(color: Colors.white)),
                  content: const Text(
                    'Delete all transfer records?',
                    style: TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              );
              if (confirm == true) await HistoryService().clear();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          const AnimatedMeshGradient(),
          SafeArea(
            child: ValueListenableBuilder<List<TransferRecord>>(
              valueListenable: HistoryService().records,
              builder: (context, records, _) {
                if (records.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.history,
                            size: 64, color: Colors.white24),
                        const SizedBox(height: 16),
                        Text(
                          'No transfers yet',
                          style: GoogleFonts.outfit(
                            color: Colors.white38,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ).animate().fadeIn(),
                  );
                }

                return ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final r = records[index];
                    return _HistoryCard(record: r, index: index);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final TransferRecord record;
  final int index;
  const _HistoryCard({required this.record, required this.index});

  @override
  Widget build(BuildContext context) {
    final isSent = record.direction == 'sent';
    final color =
        isSent ? const Color(0xFFBB86FC) : const Color(0xFF03DAC6);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        opacity: 0.08,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isSent ? Icons.upload_rounded : Icons.download_rounded,
                  color: color,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.fileName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          record.formattedSize,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 12),
                        ),
                        if (record.formattedSpeed.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Text('·',
                              style: TextStyle(color: Colors.white30)),
                          const SizedBox(width: 8),
                          Text(
                            record.formattedSpeed,
                            style:
                                TextStyle(color: color, fontSize: 12),
                          ),
                        ],
                        if (record.formattedDuration.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Text('·',
                              style: TextStyle(color: Colors.white30)),
                          const SizedBox(width: 8),
                          Text(
                            record.formattedDuration,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    isSent ? 'Sent' : 'Received',
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(record.timestamp),
                    style:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).animate(delay: (index * 40).ms).fadeIn().slideX(begin: 0.05, end: 0);
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
