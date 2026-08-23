import 'package:flutter/material.dart';

import '../db/keystore_key.dart';
import '../services/key_escrow.dart';

/// The Diagnostics row for Trail's own key escrow.
///
/// Self-contained on purpose: it loads its own [EscrowStatus] so the
/// Diagnostics screen needs a single insertion rather than a field, a
/// `_refresh` entry and a tile. The text itself comes from the pure
/// [describeKeyEscrow] in `services/key_escrow.dart`, which is where the
/// wording is unit-tested.
class KeyEscrowTile extends StatefulWidget {
  const KeyEscrowTile({super.key});

  @override
  State<KeyEscrowTile> createState() => _KeyEscrowTileState();
}

class _KeyEscrowTileState extends State<KeyEscrowTile> {
  late Future<EscrowStatus> _status;

  @override
  void initState() {
    super.initState();
    _status = KeyEscrow.instance.status();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EscrowStatus>(
      future: _status,
      builder: (context, snapshot) {
        final status = snapshot.data;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.enhanced_encryption_outlined),
          title: Text(
            status == null
                ? 'Key escrow: reading…'
                : describeKeyEscrow(
                    status: status,
                    lastReadSource: KeystoreKey.lastReadSource,
                    lastSecureStorageError: KeystoreKey.lastSecureStorageError,
                  ),
          ),
          subtitle: const Text(
            'Trail keeps its own encrypted copy of the database key, '
            'independent of the secure-storage plugin. It is read only '
            'when secure storage cannot answer.',
          ),
        );
      },
    );
  }
}
