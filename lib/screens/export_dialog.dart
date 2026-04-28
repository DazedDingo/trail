import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import '../services/encrypted_export_service.dart';
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
  bool _encrypt = false;
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

      String? passphrase;
      if (_encrypt) {
        if (!mounted) return;
        passphrase = await _promptPassphrase();
        if (passphrase == null) {
          // User cancelled — abort the share, leave the plaintext
          // exports on disk in the temp dir for the OS to GC.
          setState(() => _working = false);
          return;
        }
      }

      final shareFiles = passphrase == null
          ? files
          : <String>[await _bundleEncryptedZip(files, passphrase)];

      if (!mounted) return;
      Navigator.of(context).pop();
      await Share.shareXFiles(
        shareFiles.map(XFile.new).toList(),
        subject: 'Trail export ($_rangeLabel)'
            '${_encrypt ? ' — encrypted zip' : ''}',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '$e';
      });
    }
  }

  /// Bundles every file in [paths] into a single AES-256 encrypted
  /// zip via the native zip4j plugin and returns the zip path. The
  /// plaintext temp files are best-effort deleted afterwards so a
  /// careless OS file manager can't surface them.
  Future<String> _bundleEncryptedZip(
    List<String> paths,
    String passphrase,
  ) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    final zipPath = p.join(dir.path, 'trail_export_$ts.zip');
    await EncryptedExportService.createZip(
      inputPaths: paths,
      outputPath: zipPath,
      passphrase: passphrase,
    );
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {/* best-effort */}
    }
    return zipPath;
  }

  /// Bottom-sheet-style passphrase dialog with the same validation
  /// rules `EncryptedExportService` uses. Returns the passphrase, or
  /// `null` if the user cancelled.
  Future<String?> _promptPassphrase() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Encrypt export'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick a passphrase. Output is a standard AES-256 '
                'encrypted zip — open it with 7-Zip, macOS Archive '
                'Utility, or Linux `7z x`. No Trail-specific tooling '
                'needed on the recipient side.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase',
                ),
                validator: EncryptedExportService.validatePassphrase,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(c, controller.text);
              }
            },
            child: const Text('Encrypt + share'),
          ),
        ],
      ),
    );
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
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.lock_outline),
              title: const Text('Encrypt with passphrase'),
              subtitle: const Text(
                'AES-256 zip. Open with 7-Zip / Archive Utility / 7z.',
              ),
              isThreeLine: true,
              value: _encrypt,
              onChanged: _working
                  ? null
                  : (v) => setState(() => _encrypt = v),
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
