import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/models.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'pairing_code_sheet.dart';

/// Create or edit an employee, including their profile photo.
class EmployeeFormScreen extends StatefulWidget {
  const EmployeeFormScreen({super.key, this.existing});
  final EmployeeDetail? existing;

  @override
  State<EmployeeFormScreen> createState() => _EmployeeFormScreenState();
}

class _EmployeeFormScreenState extends State<EmployeeFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.existing?.employee.code);
  late final _name = TextEditingController(text: widget.existing?.employee.name);
  late final _phone = TextEditingController(text: widget.existing?.employee.phone);
  late final _role = TextEditingController(text: widget.existing?.employee.roleTitle ?? 'Cleaning Staff');
  late int? _teamId = widget.existing?.employee.teamId;
  XFile? _photo;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_code, _name, _phone, _role]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final file = await ImagePicker().pickImage(source: source, maxWidth: 800, maxHeight: 800, imageQuality: 85);
    if (file != null) setState(() => _photo = file);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    final store = context.read<AdminStore>();
    final body = {
      'employee_code': _code.text.trim(),
      'full_name': _name.text.trim(),
      'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      'role_title': _role.text.trim().isEmpty ? null : _role.text.trim(),
      'team_id': _teamId,
    };
    try {
      var json = _editing
          ? await api.patch('/employees/${widget.existing!.employee.id}', body)
          : await api.post('/employees', body);
      final id = (json as Map<String, dynamic>)['id'] as int;
      if (_photo != null) {
        final type = _photo!.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
        json = await api.uploadFile('/employees/$id/photo', 'file', File(_photo!.path), type);
      }
      final saved = Employee.fromJson(json as Map<String, dynamic>);
      store.upsert(saved);
      if (!mounted) return;
      // Natural next step for a new employee: pair their phone.
      if (!_editing) await showPairingCodeSheet(context, saved);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deactivateOrDelete() async {
    final employee = widget.existing!.employee;
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${employee.name}?'),
        content: const Text(
            'Deactivate keeps their location history for reports and unpairs their phone. Delete permanently erases the employee and all their location history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete', style: TextStyle(color: AppColors.offline))),
          FilledButton(onPressed: () => Navigator.pop(context, 'deactivate'), child: const Text('Deactivate')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final api = context.read<ApiClient>();
    final store = context.read<AdminStore>();
    try {
      if (choice == 'delete') {
        await api.delete('/employees/${employee.id}');
        store.remove(employee.id);
      } else {
        await api.patch('/employees/${employee.id}', {'active': false});
        store.remove(employee.id);
      }
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final api = context.read<ApiClient>();
    final existing = widget.existing?.employee;

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              BackHeader(title: _editing ? 'Edit Employee' : 'Add Employee'),
              Expanded(
                child: Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      Center(
                        child: GestureDetector(
                          onTap: () => showModalBottomSheet(
                            context: context,
                            builder: (sheet) => SafeArea(
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                ListTile(
                                  leading: const Icon(Icons.photo_camera_outlined),
                                  title: const Text('Take photo'),
                                  onTap: () {
                                    Navigator.pop(sheet);
                                    _pickPhoto(ImageSource.camera);
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.photo_library_outlined),
                                  title: const Text('Choose from gallery'),
                                  onTap: () {
                                    Navigator.pop(sheet);
                                    _pickPhoto(ImageSource.gallery);
                                  },
                                ),
                              ]),
                            ),
                          ),
                          child: Stack(
                            children: [
                              ClipOval(
                                child: SizedBox(
                                  width: 104,
                                  height: 104,
                                  child: _photo != null
                                      ? Image.file(File(_photo!.path), fit: BoxFit.cover)
                                      : existing != null
                                          ? EmployeeAvatar(employee: existing, api: api, size: 104)
                                          : const ColoredBox(
                                              color: AppColors.orangeSoft,
                                              child: Icon(Icons.person_rounded, size: 56, color: AppColors.orange),
                                            ),
                                ),
                              ),
                              const Positioned(
                                right: 0,
                                bottom: 0,
                                child: CircleAvatar(
                                  radius: 17,
                                  backgroundColor: AppColors.orange,
                                  child: Icon(Icons.camera_alt_rounded, size: 18, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      GlassCard(
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(labelText: 'Full name'),
                              validator: (v) => v == null || v.trim().isEmpty ? 'Enter the employee\'s name' : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _code,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(labelText: 'Employee ID', hintText: 'e.g. SLG-0142'),
                              validator: (v) => v == null || v.trim().isEmpty ? 'Enter the employee ID' : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _phone,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(labelText: 'Mobile number', hintText: '+91 …'),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(controller: _role, decoration: const InputDecoration(labelText: 'Role', hintText: 'Cleaning Staff')),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int?>(
                              initialValue: _teamId,
                              decoration: const InputDecoration(labelText: 'Team'),
                              items: [
                                const DropdownMenuItem(value: null, child: Text('No team')),
                                for (final t in store.teams) DropdownMenuItem(value: t.id, child: Text(t.name)),
                              ],
                              onChanged: (v) => setState(() => _teamId = v),
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[const SizedBox(height: 14), ErrorBanner(message: _error!)],
                      const SizedBox(height: 22),
                      PrimaryButton(label: _editing ? 'Save Changes' : 'Add Employee', icon: Icons.check_rounded, busy: _saving, onPressed: _save),
                      if (_editing) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _deactivateOrDelete,
                          child: const Text('Remove employee', style: TextStyle(color: AppColors.offline)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
