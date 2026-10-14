import 'package:flutter/material.dart';

import '../../app_lock/services/lock_session.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../models/installed_app.dart';
import 'protection_success_screen.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Screen F: manage installed apps - search, filters, lock toggles backed by
/// real installed-app discovery and persistent state.
class ManageAppsScreen extends StatefulWidget {
  const ManageAppsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ManageAppsScreen> createState() => _ManageAppsScreenState();
}

class _ManageAppsScreenState extends State<ManageAppsScreen>
    with AutomaticKeepAliveClientMixin {
  String _query = '';
  _Filter _filter = _Filter.all;
  bool _initialized = false;
  final FocusNode _searchFocus = FocusNode();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Rebuild on focus change so the search border can turn blue.
    _searchFocus.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadInstalledApps();
      setState(() => _initialized = true);
    });
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  List<InstalledApp> get _filtered {
    final controller = widget.controller;
    final query = _query.trim().toLowerCase();
    return controller.installedApps.where((app) {
      if (app.packageName == LockSession.selfPackage) return false;
      final locked = controller.isLocked(app.packageName);
      if (_filter == _Filter.protectedOnly && !locked) return false;
      if (_filter == _Filter.unprotected && locked) return false;
      if (query.isEmpty) return true;
      return app.label.toLowerCase().contains(query) ||
          app.packageName.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _toggle(InstalledApp app, bool lock) async {
    final ok =
        await widget.controller.setPackageLocked(app.packageName, lock);
    if (!ok || !mounted) return;
    if (lock) {
      // Protection success feedback (Screen L) - reflects real state.
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProtectionSuccessScreen(
            controller: widget.controller,
            app: app,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${app.label} is no longer protected.'),
          backgroundColor: AppColors.textPrimary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Protect Apps',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${controller.protectedCount} '
                        '${controller.protectedCount == 1 ? 'app' : 'apps'} protected',
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _searchField(),
                      const SizedBox(height: 12),
                      _filterChips(),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                Expanded(child: _body(controller)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _searchField() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _searchFocus.hasFocus
              ? AppColors.primary
              : AppColors.border,
          width: _searchFocus.hasFocus ? 1.5 : 1,
        ),
      ),
      child: TextField(
        focusNode: _searchFocus,
        onChanged: (value) => setState(() => _query = value),
        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 13),
          prefixIcon: Icon(Icons.search, size: 20, color: AppColors.textSecondary),
          hintText: 'Search apps',
          hintStyle: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _filterChips() {
    Widget chip(String label, _Filter value) {
      final selected = _filter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => setState(() => _filter = value),
          selectedColor: AppColors.paleBlue,
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.border),
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          showCheckmark: false,
        ),
      );
    }

    return Row(
      children: [
        chip('All', _Filter.all),
        chip('Protected', _Filter.protectedOnly),
        chip('Unprotected', _Filter.unprotected),
      ],
    );
  }

  Widget _body(AppController controller) {
    if (!_initialized || (controller.appsLoading && controller.installedApps.isEmpty)) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (controller.appsError != null && controller.installedApps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 40, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text(
                controller.appsError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 180,
                child: PrimaryButton(
                  label: 'Retry',
                  onPressed: () => controller.loadInstalledApps(force: true),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final apps = _filtered;
    if (apps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.paleBlueSoft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.search_off,
                    size: 28, color: AppColors.primary),
              ),
              const SizedBox(height: 14),
              Text(
                _query.isNotEmpty || _filter != _Filter.all
                    ? 'No apps match your search'
                    : 'No apps protected yet',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Try a different search or filter to find apps.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => controller.loadInstalledApps(force: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        itemCount: apps.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          final app = apps[index];
          final locked = controller.isLocked(app.packageName);
          return _AppRow(
            app: app,
            locked: locked,
            onChanged: (value) => _toggle(app, value),
          );
        },
      ),
    );
  }
}

enum _Filter { all, protectedOnly, unprotected }

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.locked,
    required this.onChanged,
  });

  final InstalledApp app;
  final bool locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _appIcon(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  app.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (locked)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: StatusPill(label: 'Protected', tone: StatusTone.neutral),
            ),
          Switch(
            value: locked,
            onChanged: onChanged,
            activeTrackColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _appIcon() {
    final bytes = app.iconBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 44,
        height: 44,
        child: bytes != null && bytes.isNotEmpty
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: AppColors.paleBlueSoft,
                child: Center(
                  child: Text(
                    app.label.isEmpty
                        ? '?'
                        : app.label.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
