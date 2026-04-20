import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import '../services/export/csv_exporter.dart';
import '../services/export/gpx_exporter.dart';

/// Format toggles for the date-range export dialog.
enum ExportFormat { gpxAndCsv, gpxOnly, csvOnly }

/// Returns the pings whose UTC timestamp falls inside [range]. The
/// picker returns `end` as a date-only DateTime at 00:00 local, so we
/// bump it to the following midnight — "2026-04-20 → 2026-04-20" then
/// includes every ping from that day, not just the midnight instant.
///
/// When [range] is null (the "All history" preset), [rows] is returned
/// unchanged.
List<Ping> filterPingsByRange(List<Ping> rows, DateTimeRange? range) {
  if (range == null) return rows;
  final startUtc = range.start.toUtc();
  final endOfDay = DateTime(range.end.year, range.end.month, range.end.day)
      .add(const Duration(days: 1));
  final endUtc = endOfDay.toUtc();
  return rows
      .where((p) =>
          !p.timestampUtc.isBefore(startUtc) &&
          p.timestampUtc.isBefore(endUtc))
      .toList(growable: false);
}

/// Modal that lets the user pick a date range + format before exporting.
///
/// Phase 6 replaces the home-screen's "Export GPX" / "Export CSV"
/// buttons (both of which dumped ALL history) with a single "Export…"
/// entry that opens this dialog. "All history" is still a one-tap
/// preset, but now the user can also ship just the last week or a
/// specific trip's worth of pings without shelling out to the archive
/// flow (which is destructive).
class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  static const _allHistoryLabel = 'All history';

  DateTimeRange? _range;
  ExportFormat _format = ExportFormat.gpxAndCsv;
  bool _working = false;
  String? _error;

  String get _rangeLabel {
    final r = _range;
    if (r == null) return _allHistoryLabel;
    final fmt = DateFormat.yMd();
    return '${fmt.format(r.start)} → ${fmt.format(r.end)}';
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: _range ??
          DateTimeRange(
            start: now.subtract(const Duration(days: 7)),
            end: now,
          ),
    );
    if (picked == null) return;
    setState(() => _range = picked);
  }

  Future<void> _run() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final db = await TrailDatabase.shared();
      final rows = await PingDao(db).all();
      final filtered = filterPingsByRange(rows, _range);
      if (filtered.isEmpty) {
        setState(() {
          _working = false;
          _error = 'No pings in the selected range.';
        });
        return;
      }
      final files = <String>[];
      if (_format == ExportFormat.gpxAndCsv ||
          _format == ExportFormat.gpxOnly) {
        files.add(await GpxExporter().export(filtered));
      }
      if (_format == ExportFormat.gpxAndCsv ||
          _format == ExportFormat.csvOnly) {
        files.add(await CsvExporter().export(filtered));
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      await Share.shareXFiles(
        files.map(XFile.new).toList(),
        subject: 'Trail export ($_rangeLabel)',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export history'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Pick a date range and format. "All history" is the full '
              'DB (same as the old export buttons).',
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.date_range_outlined),
              title: const Text('Date range'),
              subtitle: Text(_rangeLabel),
              trailing: Wrap(
                spacing: 4,
                children: [
                  if (_range != null)
                    TextButton(
                      onPressed: _working
                          ? null
                          : () => setState(() => _range = null),
                      child: const Text('All'),
                    ),
                  TextButton(
                    onPressed: _working ? null : _pickRange,
                    child: const Text('Change'),
                  ),
                ],
              ),
            ),
            const Divider(),
            RadioGroup<ExportFormat>(
              groupValue: _format,
              onChanged: (v) {
                if (_working) return;
                if (v != null) setState(() => _format = v);
              },
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 4),
                    child: Text('Format'),
                  ),
                  RadioListTile<ExportFormat>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('GPX + CSV'),
                    value: ExportFormat.gpxAndCsv,
                  ),
                  RadioListTile<ExportFormat>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('GPX only'),
                    value: ExportFormat.gpxOnly,
                  ),
                  RadioListTile<ExportFormat>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('CSV only'),
                    value: ExportFormat.csvOnly,
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _working ? null : _run,
          icon: _working
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.ios_share),
          label: const Text('Export'),
        ),
      ],
    );
  }
}
