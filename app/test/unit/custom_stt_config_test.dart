import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';

void main() {
  group('CustomSttConfig privacy policy migration (T10)', () {
    test('absent privacy_policy and send_raw_audio_to_omi:false migrates to transcriptOnly', () {
      final config = CustomSttConfig.fromJson({
        'provider': 'customLive',
        'send_raw_audio_to_omi': false,
      });

      expect(config.privacyPolicy, SttPrivacyPolicy.transcriptOnly);
    });

    test('absent privacy_policy and send_raw_audio_to_omi:true migrates to full', () {
      final config = CustomSttConfig.fromJson({
        'provider': 'customLive',
        'send_raw_audio_to_omi': true,
      });

      expect(config.privacyPolicy, SttPrivacyPolicy.full);
    });

    test('absent privacy_policy and absent send_raw_audio_to_omi migrates to full (unchanged default)', () {
      final config = CustomSttConfig.fromJson({'provider': 'customLive'});

      expect(config.privacyPolicy, SttPrivacyPolicy.full);
    });

    test('privacy_policy present and valid takes precedence over the legacy boolean', () {
      final config = CustomSttConfig.fromJson({
        'provider': 'customLive',
        'privacy_policy': 'localOnly',
        // A legacy value that would otherwise migrate to transcriptOnly must
        // NOT override an explicit, valid privacy_policy.
        'send_raw_audio_to_omi': false,
      });

      expect(config.privacyPolicy, SttPrivacyPolicy.localOnly);
    });

    test('unknown/garbage privacy_policy fails closed to full, not to a half-configured private mode', () {
      final config = CustomSttConfig.fromJson({
        'provider': 'customLive',
        'privacy_policy': 'not_a_real_policy',
        'send_raw_audio_to_omi': false,
      });

      expect(config.privacyPolicy, SttPrivacyPolicy.full);
    });

    test('privacy_policy round-trips through toJson using the policy name', () {
      const config = CustomSttConfig(provider: SttProvider.customLive, privacyPolicy: SttPrivacyPolicy.localOnly);

      expect(config.toJson()['privacy_policy'], 'localOnly');
      expect(config.toJson().containsKey('send_raw_audio_to_omi'), isFalse);

      final roundTripped = CustomSttConfig.fromJson(config.toJson());
      expect(roundTripped.privacyPolicy, SttPrivacyPolicy.localOnly);
    });

    test('privacy policy participates in the config identity (sttConfigId)', () {
      final full = CustomSttConfig.fromJson({'provider': 'customLive', 'privacy_policy': 'full'});
      final transcriptOnly = CustomSttConfig.fromJson({'provider': 'customLive', 'privacy_policy': 'transcriptOnly'});
      final localOnly = CustomSttConfig.fromJson({'provider': 'customLive', 'privacy_policy': 'localOnly'});

      expect(full.sttConfigId, isNot(transcriptOnly.sttConfigId));
      expect(transcriptOnly.sttConfigId, isNot(localOnly.sttConfigId));
      expect(full.sttConfigId, isNot(localOnly.sttConfigId));
    });

    test('forwardsRawAudioToOmi and isLocalOnlyPolicy conveniences reflect the policy', () {
      const full = CustomSttConfig(provider: SttProvider.customLive, privacyPolicy: SttPrivacyPolicy.full);
      const transcriptOnly =
          CustomSttConfig(provider: SttProvider.customLive, privacyPolicy: SttPrivacyPolicy.transcriptOnly);
      const localOnly = CustomSttConfig(provider: SttProvider.customLive, privacyPolicy: SttPrivacyPolicy.localOnly);

      expect(full.forwardsRawAudioToOmi, isTrue);
      expect(full.isLocalOnlyPolicy, isFalse);

      expect(transcriptOnly.forwardsRawAudioToOmi, isFalse);
      expect(transcriptOnly.isLocalOnlyPolicy, isFalse);

      expect(localOnly.forwardsRawAudioToOmi, isFalse);
      expect(localOnly.isLocalOnlyPolicy, isTrue);
    });
  });
}
