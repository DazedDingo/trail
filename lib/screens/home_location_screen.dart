import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../providers/home_location_provider.dart';
import '../services/home_location_service.dart';

/// Home-location picker.
///
/// Three ways to set a home:
///   1. **Use last fix** — shortcut for the most common case ("I'm at
///      home right now, use the most recent ping").
///   2. **Type coords** — for users who want to pin a specific spot
///      via an external source (Google Maps, OS grid, etc).
///   3. Existing home can be cleared with the Clear button.
///
/// Not a map-based picker because the primary use case is "I'm
/// standing at home". A map picker adds a lot of UI cost for a
/// feature that ships purely to enable "X km from home" on the
/// last-fix card.
class HomeLocationScreen extends ConsumerStatefulWidget {
  const HomeLocationScreen({super.key});

  @override
  ConsumerState<HomeLocationScreen> createState() =>
      _HomeLocationScreenState();
}

class _HomeLocationScreenState extends ConsumerState<HomeLocationScreen> {
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _latCtrl.dispose();
    _lonCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _useLastFix() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final db = await TrailDatabase.shared();
      final last = await PingDao(db).latestSuccessful();
      if (last == null) {
        setState(() {
          _saving = false;
          _error = 'No successful pings yet — take a fix first.';
        });
        return;
      }
      await HomeLocationService.set(
        lat: last.lat!,
        lon: last.lon!,
      );
      ref.invalidate(homeLocationProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<void> _saveManual() async {
    final lat = double.tryParse(_latCtrl.text.trim());
    final lon = double.tryParse(_lonCtrl.text.trim());
    if (lat == null || lon == null) {
      setState(() => _error = 'Enter numeric lat and lon.');
      return;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      setState(() => _error = 'Lat must be [-90, 90], lon must be [-180, 180].');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await HomeLocationService.set(
        lat: lat,
        lon: lon,
        label: _labelCtrl.text.trim().isEmpty ? null : _labelCtrl.text.trim(),
      );
      ref.invalidate(homeLocationProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<void> _clear() async {
    await HomeLocationService.clear();
    ref.invalidate(homeLocationProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(homeLocationProvider).asData?.value;
    if (current != null) {
      // Pre-fill the editor with the existing value so "change" is just
      // tweak-and-save rather than re-type.
      if (_latCtrl.text.isEmpty) _latCtrl.text = current.lat.toString();
      if (_lonCtrl.text.isEmpty) _lonCtrl.text = current.lon.toString();
      if (_labelCtrl.text.isEmpty && current.label != null) {
        _labelCtrl.text = current.label!;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home location'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What this does',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Trail uses your home to show "X km from home" on '
                    'the last-fix card. Nothing is sent anywhere — it '
                    'stays in your device preferences.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (current != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.home_outlined),
                title: Text(current.label ?? 'Current home'),
                subtitle: Text(
                  '${current.lat.toStringAsFixed(5)}, '
                  '${current.lon.toStringAsFixed(5)}',
                ),
                trailing: TextButton.icon(
                  onPressed: _saving ? null : _clear,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear'),
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _useLastFix,
            icon: const Icon(Icons.my_location),
            label: const Text('Use last successful fix'),
          ),
          const SizedBox(height: 16),
          Text(
            'Or enter coords manually',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _latCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true),
            decoration: const InputDecoration(
              labelText: 'Latitude',
              helperText: 'e.g. 51.50734',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _lonCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true),
            decoration: const InputDecoration(
              labelText: 'Longitude',
              helperText: 'e.g. -0.12776',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _labelCtrl,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              helperText: 'e.g. "Flat"',
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: _saving ? null : _saveManual,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save manual coords'),
          ),
        ],
      ),
    );
  }
}
