import 'dart:convert';

import 'package:omi/models/stt_provider.dart';
import 'package:omi/models/stt_response_schema.dart';
import 'package:omi/utils/logger.dart';

/// Privacy guarantee for a Custom STT session, in increasing order of
/// isolation from Omi:
///
/// - [full] — raw audio, transcript, and conversation data all flow to Omi
///   (the pre-#10447 default).
/// - [transcriptOnly] — raw audio never reaches Omi, but the transcript is
///   still forwarded as `suggested_transcript` so conversation
///   processing/summaries stay Omi-hosted (PR #10447).
/// - [localOnly] — no Omi secondary socket is constructed at all: no audio,
///   no transcript, no conversation/summary content reaches Omi. Firebase
///   auth, Crashlytics, Intercom, analytics event counts, and subscription
///   endpoints are out of scope for this guarantee and still egress.
enum SttPrivacyPolicy { full, transcriptOnly, localOnly }

SttPrivacyPolicy? _parsePrivacyPolicy(dynamic value) {
  if (value is! String) return null;
  for (final policy in SttPrivacyPolicy.values) {
    if (policy.name == value) return policy;
  }
  return null;
}

/// Migration precedence (must match exactly — see architecture.md §5.1):
/// 1. `privacy_policy` key present and parses -> use it.
/// 2. `privacy_policy` key present but unknown/garbage -> [SttPrivacyPolicy.full]
///    (fail closed to existing behavior, never to a half-configured private
///    mode — a present-but-corrupt key means this record was already written
///    by the new code, so the legacy boolean below is not consulted).
/// 3. `privacy_policy` key absent, `send_raw_audio_to_omi == false` ->
///    [SttPrivacyPolicy.transcriptOnly] (preserves PR #10447 behavior for
///    existing pre-migration users).
/// 4. `privacy_policy` key absent, otherwise -> [SttPrivacyPolicy.full]
///    (unchanged default).
SttPrivacyPolicy _migratePrivacyPolicy(Map<String, dynamic> json) {
  if (json.containsKey('privacy_policy')) {
    return _parsePrivacyPolicy(json['privacy_policy']) ?? SttPrivacyPolicy.full;
  }
  if (json['send_raw_audio_to_omi'] == false) return SttPrivacyPolicy.transcriptOnly;
  return SttPrivacyPolicy.full;
}

class CustomSttConfig {
  final SttProvider provider;
  final String? apiKey;
  final String? language;
  final String? model;
  final String? url;
  final String? host;
  final int? port;
  final String? requestType;
  final Map<String, String>? headers;
  final Map<String, String>? params;
  final String? audioFieldName;
  final Map<String, dynamic>? schemaJson;
  final SttPrivacyPolicy privacyPolicy;

  const CustomSttConfig({
    required this.provider,
    this.apiKey,
    this.language,
    this.model,
    this.url,
    this.host,
    this.port,
    this.requestType,
    this.headers,
    this.params,
    this.audioFieldName,
    this.schemaJson,
    this.privacyPolicy = SttPrivacyPolicy.full,
  });

  /// Determine if live/streaming based on request_type
  String get effectiveRequestType => requestType ?? providerConfig.requestType;
  bool get isLive => SttRequestType.isLive(effectiveRequestType);
  bool get isPolling => SttRequestType.isPolling(effectiveRequestType);

  bool get isEnabled => provider != SttProvider.omi;

  /// Whether raw audio frames are forwarded to the Omi secondary socket.
  /// Only [SttPrivacyPolicy.full] forwards raw audio; both [SttPrivacyPolicy.transcriptOnly]
  /// and [SttPrivacyPolicy.localOnly] withhold it.
  bool get forwardsRawAudioToOmi => privacyPolicy == SttPrivacyPolicy.full;

  /// Whether this config must never construct an Omi secondary socket at all
  /// (no audio, no transcript, no conversation content reaches Omi).
  bool get isLocalOnlyPolicy => privacyPolicy == SttPrivacyPolicy.localOnly;

  SttProviderConfig get providerConfig => SttProviderConfig.get(provider);

  SttResponseSchema get schema {
    if (schemaJson != null) {
      return SttResponseSchema.fromJson(schemaJson!);
    }
    return providerConfig.responseSchema;
  }

  /// Get the effective language (user-selected or provider default)
  String get effectiveLanguage => language ?? providerConfig.defaultLanguage;

  /// Get the effective model (user-selected or provider default)
  String get effectiveModel => model ?? providerConfig.defaultModel;

  /// Get effective URL (custom or provider default)
  String get effectiveUrl {
    if (url != null && url!.isNotEmpty) return url!;
    final config = providerConfig.buildRequestConfig(
      apiKey: apiKey,
      language: language,
      model: model,
      host: host,
      port: port,
    );
    return config['url'] ?? '';
  }

  /// Build request config with all settings applied
  /// Merges user customizations with provider defaults (user values win)
  Map<String, dynamic> get requestConfig {
    // Get provider defaults (works for all providers including custom)
    final config = providerConfig.buildRequestConfig(
      apiKey: apiKey,
      language: language,
      model: model,
      host: host,
      port: port,
    );

    final defaultParams = Map<String, String>.from(config['params'] ?? {});
    final defaultHeaders = Map<String, String>.from(config['headers'] ?? {});

    // Merge user params with defaults (user values override defaults)
    if (params != null && params!.isNotEmpty) {
      config['params'] = {...defaultParams, ...params!};
    }

    // Merge user headers with defaults (user values override defaults)
    if (headers != null && headers!.isNotEmpty) {
      config['headers'] = {...defaultHeaders, ...headers!};
    }

    // Apply explicit overrides
    if (url != null && url!.isNotEmpty) config['url'] = url;
    if (requestType != null) config['request_type'] = requestType;
    if (audioFieldName != null) config['audio_field_name'] = audioFieldName;

    return config;
  }

  String get sttConfigId {
    if (!isEnabled) return 'omi:default';

    final configData = {
      'api_key': apiKey,
      'language': language,
      'model': model,
      'url': url,
      'host': host,
      'port': port,
      'request_type': requestType,
      'headers': headers,
      'params': params,
      // Correctness requirement, not cosmetics: SocketServicePool.socket()
      // reuses a live socket whenever sttConfigId is unchanged, so the policy
      // must participate in the hash or a policy change would leave the old
      // composite (and its live Omi socket) running. See sockets.dart:62-72.
      'privacy_policy': privacyPolicy.name,
    };

    final jsonStr = jsonEncode(configData);
    final hashValue = jsonStr.hashCode.abs();
    final hash = hashValue.toRadixString(16).padLeft(8, '0').substring(0, 8);
    Logger.debug('${provider.name}:$hash');
    return '${provider.name}:$hash';
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'api_key': apiKey,
        'language': language,
        'model': model,
        'url': url,
        'host': host,
        'port': port,
        'request_type': requestType,
        'headers': headers,
        'params': params,
        'audio_field_name': audioFieldName,
        'schema': schemaJson,
        'privacy_policy': privacyPolicy.name,
      };

  factory CustomSttConfig.fromJson(Map<String, dynamic> json) {
    // Safely cast maps to Map<String, String> by converting all values to strings
    Map<String, String>? safeStringMap(dynamic value) {
      if (value == null) return null;
      if (value is Map) {
        return value.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
      return null;
    }

    return CustomSttConfig(
      provider: SttProvider.fromString(json['provider'] ?? 'omi'),
      apiKey: json['api_key'],
      language: json['language'],
      model: json['model'],
      url: json['url'],
      host: json['host'],
      port: json['port'],
      requestType: json['request_type'],
      headers: safeStringMap(json['headers']),
      params: safeStringMap(json['params']),
      audioFieldName: json['audio_field_name'],
      schemaJson: json['schema'] != null ? Map<String, dynamic>.from(json['schema']) : null,
      privacyPolicy: _migratePrivacyPolicy(json),
    );
  }

  static const defaultConfig = CustomSttConfig(provider: SttProvider.omi);

  /// Copy with new values
  CustomSttConfig copyWith({
    SttProvider? provider,
    String? apiKey,
    String? language,
    String? model,
    String? url,
    String? host,
    int? port,
    String? requestType,
    Map<String, String>? headers,
    Map<String, String>? params,
    String? audioFieldName,
    Map<String, dynamic>? schemaJson,
    SttPrivacyPolicy? privacyPolicy,
  }) {
    return CustomSttConfig(
      provider: provider ?? this.provider,
      apiKey: apiKey ?? this.apiKey,
      language: language ?? this.language,
      model: model ?? this.model,
      url: url ?? this.url,
      host: host ?? this.host,
      port: port ?? this.port,
      requestType: requestType ?? this.requestType,
      headers: headers ?? this.headers,
      params: params ?? this.params,
      audioFieldName: audioFieldName ?? this.audioFieldName,
      schemaJson: schemaJson ?? this.schemaJson,
      privacyPolicy: privacyPolicy ?? this.privacyPolicy,
    );
  }

  static Map<String, dynamic> getFullTemplateJson(SttProvider provider) {
    return SttProviderConfig.get(provider).getFullTemplateJson();
  }
}
