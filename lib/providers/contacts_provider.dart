import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/contact_dao.dart';
import '../db/database.dart';
import '../models/emergency_contact.dart';

/// List of configured emergency contacts, newest-inserted last (id ASC).
///
/// Feeds both the Settings → Emergency contacts screen and the panic-share
/// builder. Invalidated after every insert/update/delete from the screen so
/// the Panic button's SMS hand-off always sees the current set.
final emergencyContactsProvider =
    FutureProvider<List<EmergencyContact>>((ref) async {
  final db = await TrailDatabase.shared();
  return ContactDao(db).all();
});
