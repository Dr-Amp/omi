import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/pages/settings/transcription_settings_page.dart';
import 'package:omi/providers/capture_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('source changes restore each provider privacy policy (T2 regression guard)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();

    const onDeviceConfig = CustomSttConfig(
      provider: SttProvider.onDeviceWhisper,
      privacyPolicy: SttPrivacyPolicy.transcriptOnly,
    );
    const cloudConfig = CustomSttConfig(
      provider: SttProvider.openai,
      privacyPolicy: SttPrivacyPolicy.full,
    );
    await SharedPreferencesUtil().saveCustomSttConfig(onDeviceConfig);
    await SharedPreferencesUtil().saveConfigForProvider(SttProvider.onDeviceWhisper, onDeviceConfig);
    await SharedPreferencesUtil().saveConfigForProvider(SttProvider.openai, cloudConfig);

    final captureProvider = CaptureProvider();
    addTearDown(captureProvider.dispose);
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<CaptureProvider>.value(
        value: captureProvider,
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TranscriptionSettingsPage(),
        ),
      ),
    );
    await tester.pump();

    // The transcriptOnly option is selected for the on-device provider.
    expect(find.byKey(const Key('stt_privacy_policy_transcript_only')), findsOneWidget);
    expect(find.byKey(const Key('stt_privacy_policy_full')), findsOneWidget);
    expect(find.byKey(const Key('stt_privacy_policy_local_only')), findsOneWidget);

    final sourceDropdown = tester.widget<DropdownButton<TranscriptionMode>>(
      find.byType(DropdownButton<TranscriptionMode>),
    );
    sourceDropdown.onChanged!(TranscriptionMode.cloudProvider);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(
      SharedPreferencesUtil().getConfigForProvider(SttProvider.onDeviceWhisper)?.privacyPolicy,
      SttPrivacyPolicy.transcriptOnly,
    );
  });

  testWidgets('tapping the localOnly option updates the stored provider config', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();

    const cloudConfig = CustomSttConfig(
      provider: SttProvider.customLive,
      url: 'wss://stt.example.test/live',
      privacyPolicy: SttPrivacyPolicy.full,
    );
    await SharedPreferencesUtil().saveCustomSttConfig(cloudConfig);
    await SharedPreferencesUtil().saveConfigForProvider(SttProvider.customLive, cloudConfig);

    final captureProvider = CaptureProvider();
    addTearDown(captureProvider.dispose);
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<CaptureProvider>.value(
        value: captureProvider,
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TranscriptionSettingsPage(),
        ),
      ),
    );
    await tester.pump();

    final localOnlyOption = find.byKey(const Key('stt_privacy_policy_local_only'));
    await tester.ensureVisible(localOnlyOption);
    await tester.pumpAndSettle();
    await tester.tap(localOnlyOption);
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(ElevatedButton, 'Save');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(SharedPreferencesUtil().customSttConfig.privacyPolicy, SttPrivacyPolicy.localOnly);
  });
}
