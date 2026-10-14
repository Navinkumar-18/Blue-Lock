import 'package:flutter/material.dart';

import '../../app_lock/services/lock_session.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../models/installed_app.dart';
import 'protection_success_screen.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Screen F: manage installed apps - search, filters, lock toggles backed by
/// real installed-app discovery and persistent state.
///
/// Rebuild scoping: the search field, filter chips, protected-count header
/// and the scrolling list are independent listening widgets. Typing, tapping
/// a filter chip, toggling one switch or a background controller
/// notification each rebuild only the part that depends on the changed
/// value - never the whole screen.
class ManageAppsScreen extends StatefulWidget {
  const ManageAppsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ManageAppsScreen> createState() => _ManageAppsScreenState();
}

class _ManageAppsScreenState extends State<ManageAppsScreen>
    with AutomaticKeepAliveClientMixin {
  /// Live search text; written by [_SearchField], read by the list body.
  final ValueNotifier<String> _query = ValueNotifier<String>('');

  /// Active filter chip; written by the chips row, read by the list body.
  final ValueNotifier<_Filter> _filter = ValueNotifier<_Filter>(_Filter.all);

  bool _initialized = false;

  // Memo of the last filter pass, keyed by every input that can change it.
  // The controller replaces the app list and the locked-packages set
  // wholesale whenever either changes, so identity matches mean the cached
  // result is still current (search text and filter are compared by value).
  List<InstalledApp>? _filteredCache;
  List<InstalledApp>? _cacheAppsRef;
  Set<String>? _cacheLockedRef;
  String _cacheQuery = '';
  _Filter _cacheFilter = _Filter.all;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadInstalledApps();
      setState(() => _initialized = true);
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _filter.dispose();
    super.dispose();
  }

  List<InstalledApp> _filtered(AppController controller) {
    final query = _query.value.trim().toLowerCase();
    final filter = _filter.value;
    final apps = controller.installedApps;
    final locked = controller.lockedPackages;
    final cached = _filteredCache;
    if (cached != null &&
        identical(apps, _cacheAppsRef) &&
        identical(locked, _cacheLockedRef) &&
        query == _cacheQuery &&
        filter == _cacheFilter) {
      return cached;
    }
    final result = <InstalledApp>[];
    for (final app in apps) {
      if (app.packageName == LockSession.selfPackage) continue;
      final isLocked = locked.contains(app.packageName);
      if (filter == _Filter.protectedOnly && !isLocked) continue;
      if (filter == _Filter.unprotected && isLocked) continue;
      if (query.isNotEmpty &&
          !app.label.toLowerCase().contains(query) &&
          !app.packageName.toLowerCase().contains(query)) {
        continue;
      }
      result.add(app);
    }
    _filteredCache = result;
    _cacheAppsRef = apps;
    _cacheLockedRef = locked;
    _cacheQuery = query;
    _cacheFilter = filter;
    return result;
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
        child: Column(
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
                  _ProtectedCount(controller: controller),
                  const SizedBox(height: 14),
                  _SearchField(query: _query),
                  const SizedBox(height: 12),
                  _FilterChips(filter: _filter),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Expanded(
              // Search text changes rebuild only this subtree; filter chip
              // changes and controller notifications rebuild only the
              // innermost list builder.
              child: ValueListenableBuilder<String>(
                valueListenable: _query,
                builder: (context, query, _) {
                  return ValueListenableBuilder<_Filter>(
                    valueListenable: _filter,
                    builder: (context, filter, _) {
                      return ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => _body(controller),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppController controller) {
    if (!_initialized ||
        (controller.appsLoading && controller.installedApps.isEmpty)) {
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

    final apps = _filtered(controller);
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
                _query.value.isNotEmpty || _filter.value != _Filter.all
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
        // Stable keys keep row state (switch position, text ellipsis
        // layout) attached to the same package when the list reorders
        // under search and filters.
        itemBuilder: (context, index) {
          final app = apps[index];
          final locked = controller.isLocked(app.packageName);
          return _AppRow(
            key: ValueKey(app.packageName),
            app: app,
            locked: locked,
            onChanged: (value) => _toggle(app, value),
          );
        },
        separatorBuilder: (_, _) => const Divider(),
      ),
    );
  }
}

enum _Filter { all, protectedOnly, unprotected }

/// Protected-app counter: rebuilds alone when a toggle changes the count.
class _ProtectedCount extends StatelessWidget {
  const _ProtectedCount({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Text(
          '${controller.protectedCount} '
          '${controller.protectedCount == 1 ? 'app' : 'apps'} protected',
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.textSecondary,
          ),
        );
      },
    );
  }
}

/// Search input: owns its focus state, so focus changes and typing never
/// rebuild the rest of the screen.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.query});

  final ValueNotifier<String> query;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Rebuild locally on focus change so the search border can turn blue.
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _focus.hasFocus ? AppColors.primary : AppColors.border,
          width: _focus.hasFocus ? 1.5 : 1,
        ),
      ),
      child: TextField(
        focusNode: _focus,
        onChanged: (value) => widget.query.value = value,
        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 13),
          prefixIcon:
              Icon(Icons.search, size: 20, color: AppColors.textSecondary),
          hintText: 'Search apps',
          hintStyle: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// Filter chips: rebuild only themselves when the selection changes.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.filter});

  final ValueNotifier<_Filter> filter;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, _Filter value) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: filter.value == value,
          onSelected: (_) => filter.value = value,
          selectedColor: AppColors.paleBlue,
          backgroundColor: AppColors.surface,
          side: const BorderSide(color: AppColors.border),
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: filter.value == value
                ? AppColors.primary
                : AppColors.textSecondary,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          showCheckmark: false,
        ),
      );
    }

    return ValueListenableBuilder<_Filter>(
      valueListenable: filter,
      builder: (context, active, _) {
        return Row(
          children: [
            chip('All', _Filter.all),
            chip('Protected', _Filter.protectedOnly),
            chip('Unprotected', _Filter.unprotected),
          ],
        );
      },
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    super.key,
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
          AppIconView(label: app.label, iconBytes: app.iconBytes),
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
}
