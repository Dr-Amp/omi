import 'package:omi/services/capture/capture_controller.dart';
import 'package:omi/services/capture/capture_external_actions.dart';
import 'package:omi/services/local_conversations/local_conversation_repository.dart';

class CaptureProvider extends CaptureController {
  CaptureProvider({CaptureExternalActions? externalActions, LocalConversationRepository? localConversationRepository})
      : super(externalActions: externalActions, localConversationRepository: localConversationRepository);
}
