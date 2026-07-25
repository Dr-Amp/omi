import 'dart:async';

import 'package:omi/utils/debug_log_manager.dart';

/// Outcome of a fallback/fail-open branch, per docs/agents/fallback-telemetry.md.
enum FallbackOutcome {
  /// Full UX restored via an alternate path.
  recovered,

  /// Continues with a reduced/degraded capability.
  degraded,

  /// No path left; the affected capability is unavailable this session.
  exhausted,
}

/// Flutter counterpart of the cross-component `record_fallback`/`recordFallback`
/// contract (docs/agents/fallback-telemetry.md). There was no Dart emitter for
/// this contract before this change — Python (backend), Swift (desktop macOS),
/// and TypeScript (desktop Windows) each have one, but `app/` did not. Rather
/// than inventing a bespoke one-off counter for a single call site, this is the
/// single Dart primitive: it reuses the existing local [DebugLogManager] sink
/// (already the de-facto shared diagnostics channel for this transport layer —
/// see transcription_service.dart / composite_transcription_socket.dart) and
/// keeps the same field contract (component/from/to/reason/outcome) so this
/// event is recognizable next to its backend/desktop counterparts. Call this,
/// not a new counter, whenever a branch changes provider, mode, or
/// correctness, or takes a fail-open (or a fail-open being *closed*) path.
void recordFallback({
  required String component,
  String? from,
  String? to,
  required String reason,
  required FallbackOutcome outcome,
  Map<String, Object?> extra = const {},
}) {
  unawaited(
    DebugLogManager.logEvent('fallback_triggered', {
      'component': component,
      'from': from ?? 'none',
      'to': to ?? 'none',
      'reason': reason,
      'outcome': outcome.name,
      ...extra,
    }),
  );
}
