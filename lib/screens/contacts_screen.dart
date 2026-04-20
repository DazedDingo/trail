import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/contact_dao.dart';
import '../db/database.dart';
import '../models/emergency_contact.dart';
import '../providers/contacts_provider.dart';

/// Emergency-contacts CRUD screen. Stored in the encrypted DB (not shared
/// prefs) per PLAN.md "contacts data" rule — PII lives alongside the
/// ping history under the same SQLCipher key.
///
/// Phone numbers are stored in E.164 form (leading `+`, country code,
/// digits). Light validation only — Flutter's `TextField` can't replace
/// the user's judgement about whether the number they typed is reachable.
class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(emergencyContactsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Emergency contacts')),
      body: contacts.when(
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(onAdd: () => _openEditor(context, ref, null));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _ContactTile(
              contact: list[i],
              onEdit: () => _openEditor(context, ref, list[i]),
              onDelete: () => _confirmDelete(context, ref, list[i]),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed: $e')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    EmergencyContact? existing,
  ) async {
    final saved = await showDialog<EmergencyContact>(
      context: context,
      builder: (_) => _ContactEditorDialog(existing: existing),
    );
    if (saved == null) return;
    final db = await TrailDatabase.shared();
    final dao = ContactDao(db);
    if (saved.id == null) {
      await dao.insert(saved);
    } else {
      await dao.update(saved);
    }
    ref.invalidate(emergencyContactsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    EmergencyContact c,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text(
          'Remove ${c.name} (${c.phoneE164}) from the panic SMS list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || c.id == null) return;
    final db = await TrailDatabase.shared();
    await ContactDao(db).delete(c.id!);
    ref.invalidate(emergencyContactsProvider);
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.contacts_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'No emergency contacts yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add people the panic button should SMS. Their numbers stay '
              'in the encrypted DB — Trail never uploads them.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add contact'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final EmergencyContact contact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ContactTile({
    required this.contact,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(
          contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?',
        ),
      ),
      title: Text(contact.name),
      subtitle: Text(contact.phoneE164),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'edit') onEdit();
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
      onTap: onEdit,
    );
  }
}

class _ContactEditorDialog extends StatefulWidget {
  final EmergencyContact? existing;
  const _ContactEditorDialog({this.existing});

  @override
  State<_ContactEditorDialog> createState() => _ContactEditorDialogState();
}

class _ContactEditorDialogState extends State<_ContactEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _phone = TextEditingController(text: widget.existing?.phoneE164 ?? '+');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    // Minimal E.164 shape check — leading +, 8–15 digits. Keeps the SMS
    // URI composition honest without refusing valid-but-unusual numbers.
    final e164 = RegExp(r'^\+\d{8,15}$');
    if (!e164.hasMatch(phone)) {
      setState(() => _error =
          'Phone must be in E.164 format: leading "+", country code, digits.');
      return;
    }
    Navigator.of(context).pop(
      EmergencyContact(
        id: widget.existing?.id,
        name: name,
        phoneE164: phone,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:
          Text(widget.existing == null ? 'Add contact' : 'Edit contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
            ],
            decoration: InputDecoration(
              labelText: 'Phone (E.164)',
              helperText: 'e.g. +447700900123',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
