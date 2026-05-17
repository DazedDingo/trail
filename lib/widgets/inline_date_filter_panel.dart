import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/stats/date_range_presets.dart';

/// Inline date-range picker for the map screen. Replaces the
/// `showDateRangePicker` modal that used to take over the whole screen.
///
/// Two interaction modes:
///   1. Tap a preset chip → range applied immediately, panel closes.
///   2. Tap "Custom range…" → falls through to the system date-range
///      picker for granular start/end selection (we use the system
///      picker here rather than embedding a CalendarDatePicker because
///      MaterialDateRangePicker is much more compact for selecting
///      two-ended ranges than the standalone CalendarDatePicker, which
///      only picks a single date — embedding it would require building
///      two-end selection logic from scratch).
///
/// The panel sits between the control row and the map body. Animated
/// in/out via [AnimatedSize] — `open=false` collapses to 0 height.
class InlineDateFilterPanel extends StatelessWidget {
  final bool open;
  final DateTimeRange? currentRange;
  final DateTime now;
  final DateTime earliestPing;
  final DateTime latestPing;
  final ValueChanged<DateTimeRange?> onApply;
  final VoidCallback onClose;

  const InlineDateFilterPanel({
    super.key,
    required this.open,
    required this.currentRange,
    required this.now,
    required this.earliestPing,
    required this.latestPing,
    required this.onApply,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: open
          ? _PanelBody(
              scheme: scheme,
              currentRange: currentRange,
              now: now,
              earliestPing: earliestPing,
              latestPing: latestPing,
              onApply: onApply,
              onClose: onClose,
            )
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}

class _PanelBody extends StatelessWidget {
  final ColorScheme scheme;
  final DateTimeRange? currentRange;
  final DateTime now;
  final DateTime earliestPing;
  final DateTime latestPing;
  final ValueChanged<DateTimeRange?> onApply;
  final VoidCallback onClose;

  const _PanelBody({
    required this.scheme,
    required this.currentRange,
    required this.now,
    required this.earliestPing,
    required this.latestPing,
    required this.onApply,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final presets = dateRangePresets(now);
    final activeId = presetIdMatching(currentRange, now);
    final fmt = DateFormat.yMMMd();
    final currentLabel = currentRange == null
        ? 'No filter (showing every ping)'
        : '${fmt.format(currentRange!.start)} – ${fmt.format(currentRange!.end)}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.date_range_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  currentLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in presets)
                _PresetChip(
                  label: preset.label,
                  selected: preset.id == activeId,
                  onTap: () => onApply(preset.range),
                ),
              _CustomRangeChip(
                onTap: () async {
                  final picked = await _showSystemPicker(context);
                  if (picked != null) onApply(picked);
                },
              ),
              if (currentRange != null)
                _ClearChip(onTap: () => onApply(null)),
            ],
          ),
        ],
      ),
    );
  }

  Future<DateTimeRange?> _showSystemPicker(BuildContext context) async {
    final initial = currentRange ??
        DateTimeRange(
          start: latestPing
              .toLocal()
              .subtract(const Duration(days: 7)),
          end: latestPing.toLocal(),
        );
    return showDateRangePicker(
      context: context,
      firstDate: earliestPing.toLocal().subtract(const Duration(days: 1)),
      lastDate: latestPing.toLocal().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: initial.start.isBefore(earliestPing.toLocal())
            ? earliestPing.toLocal()
            : initial.start,
        end: initial.end.isAfter(latestPing.toLocal())
            ? latestPing.toLocal()
            : initial.end,
      ),
      helpText: 'Filter trail by date',
      saveText: 'Apply',
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selectedColor: scheme.primary.withValues(alpha: 0.30),
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.6)
            : scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    );
  }
}

class _CustomRangeChip extends StatelessWidget {
  final VoidCallback onTap;
  const _CustomRangeChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      label: const Text('Custom range…',
          style: TextStyle(fontSize: 12)),
      avatar: Icon(Icons.tune, size: 14, color: scheme.onSurfaceVariant),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    );
  }
}

class _ClearChip extends StatelessWidget {
  final VoidCallback onTap;
  const _ClearChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      label: const Text('Clear', style: TextStyle(fontSize: 12)),
      avatar:
          Icon(Icons.cancel_outlined, size: 14, color: scheme.error),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
    );
  }
}
