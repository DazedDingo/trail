import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/full_map_panel.dart';
import '../widgets/help_button.dart';

// Re-exported so existing call sites (tests, deep-link consumers) still
// resolve `stepSliderTo` from this module after the panel lift-out.
export '../widgets/full_map_panel.dart' show stepSliderTo;

/// Full-screen wrapper around [FullMapPanel].
///
/// Pre-0.10.13 this screen carried the entire map rig (controller,
/// playback timer, annotation bookkeeping) inline. That logic now lives
/// in [FullMapPanel] so the home screen can host the same experience
/// inline. This screen is just a Scaffold + AppBar that gives the
/// `/map` route a back button and a help dialog.
class MapScreen extends ConsumerWidget {
  /// Optional pre-applied filter — set when the screen is opened via
  /// `context.push('/map', extra: DateTimeRange(...))` from elsewhere
  /// (e.g. the stats screen's heatmap day-tap or trip card). The user
  /// can still clear or change it from the calendar action.
  final DateTimeRange? initialFilter;

  const MapScreen({super.key, this.initialFilter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail map'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: const [
          HelpButton(
            screenTitle: 'Map',
            sections: [
              HelpSection(
                icon: Icons.linear_scale,
                title: 'Time slider + playback',
                body:
                    'Drag the slider to scrub through history; the trail '
                    'redraws live. Play / Pause auto-advances at 1× → 16× '
                    'speeds. The HUD top-left shows the current and '
                    'previous fix timestamps with the gap between them.',
              ),
              HelpSection(
                icon: Icons.location_on,
                title: 'Pin colours',
                body:
                    'Red = current fix (slider tip). Amber = previous fix. '
                    'Teal = earlier fixes. The blue dot is your live '
                    'location from Android — toggle it via the my-location '
                    'icon in the control row.',
              ),
              HelpSection(
                icon: Icons.date_range,
                title: 'Date filter',
                body:
                    'Calendar icon opens a date range picker. The slider, '
                    'playback, and bbox-fit clamp to the filtered window. '
                    'Tap a day on the Stats heatmap to jump here filtered '
                    'to that day.',
              ),
              HelpSection(
                icon: Icons.blur_on,
                title: 'Heatmap',
                body:
                    'Swap the line + circles for a density-weighted '
                    'heatmap layer. Useful for spotting hot spots over '
                    'months of pings without thousands of dots.',
              ),
              HelpSection(
                icon: Icons.layers_outlined,
                title: 'Regions',
                body:
                    'Layers icon opens the Regions screen — install / '
                    'switch the active offline tileset. Maps go blank if '
                    'no region is active; Trail is offline-only.',
              ),
            ],
          ),
        ],
      ),
      body: FullMapPanel(
        height: double.infinity,
        initialFilter: initialFilter,
      ),
    );
  }
}
