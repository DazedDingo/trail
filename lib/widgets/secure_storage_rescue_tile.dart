import 'package:flutter/material.dart';

import '../services/passphrase_recovery_service.dart';
import '../services/secure_storage_rescue.dart';

/// The Diagnostics rows for the secure-storage rescue (0.17.8).
///
/// Two lines, both from pure describers in
/// `services/passphrase_recovery_service.dart` (where the wording is
/// unit-tested):
///
///   * what the last rebuild recovered, from the persisted summary, and
///   * whether the plugin's store file is present or has been set aside.
///
/// Self-contained for the same reason as `KeyEscrowTile`: the Diagnostics
/// screen takes one insertion rather than two fields and a `_refresh`
/// entry. Both loads are total — off-device (or in the WorkManager
/// isolate) the channel simply reports an error into the line.
class SecureStorageRescueTile extends StatefulWidget {
  const SecureStorageRescueTile({super.key});

  @override
  State<SecureStorageRescueTile> createState() =>
      _SecureStorageRescueTileState();
}

class _SecureStorageRescueTileState extends State<SecureStorageRescueTile> {
  late Future<SecureStorageRescueSummary?> _summary;
  late Future<RescueStatus> _status;

  @override
  void initState() {
    super.initState();
    _summary = PassphraseRecoveryService.readSummary();
    _status = SecureStorageRescue.instance.status();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<SecureStorageRescueSummary?>(
          future: _summary,
          builder: (context, snapshot) => ListTile(
            dense: true,
            leading: const Icon(Icons.healing_outlined),
            title: Text(
              snapshot.connectionState == ConnectionState.done
                  ? describeSecureStorageRescue(snapshot.data)
                  : 'Secure storage rescue: reading…',
            ),
            subtitle: const Text(
              'Run only when unlocking with the backup passphrase found '
              'the secure-storage plugin broken. Nothing is deleted — the '
              'old store is copied aside first.',
            ),
          ),
        ),
        FutureBuilder<RescueStatus>(
          future: _status,
          builder: (context, snapshot) {
            final status = snapshot.data;
            return ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined),
              title: Text(
                status == null
                    ? 'Secure storage store file: reading…'
                    : describeSecureStorageStoreFile(status),
              ),
            );
          },
        ),
      ],
    );
  }
}
