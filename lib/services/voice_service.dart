import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isListening = false;

  bool get isListening => _isListening;

  Future<void> init() async {
    if (_isInitialized) return;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        _isListening = false;
      },
    );

    // Configure TTS
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(0.85); // slightly lower pitch reads as more male
    await _setMaleVoice();
  }

  /// Picks the first available male English voice on the device, if any.
  /// Falls back silently to the system default voice if none is found
  /// (some Android builds don't expose a "gender" field).
  Future<void> _setMaleVoice() async {
    try {
      final voices = await _tts.getVoices as List<dynamic>?;
      if (voices == null) return;

      Map<String, String>? chosen;
      for (final v in voices) {
        final map = Map<String, dynamic>.from(v as Map);
        final name = (map['name'] ?? '').toString().toLowerCase();
        final locale = (map['locale'] ?? '').toString().toLowerCase();
        if (!locale.startsWith('en')) continue;
        // Common male-voice naming patterns across Android TTS engines.
        if (name.contains('male') ||
            name.contains('#male') ||
            name.contains('-d ') ||
            name.endsWith('-d') ||
            name.contains('en-us-x-iom') || // Google's male en-US variant
            name.contains('en-us-x-iol') ||
            name.contains('en-us-x-tpc')) {
          chosen = {
            'name': map['name'].toString(),
            'locale': map['locale'].toString(),
          };
          break;
        }
      }

      if (chosen != null) {
        await _tts.setVoice(chosen);
      }
    } catch (_) {
      // Voice query not supported on this device/engine — keep default.
    }
  }

  /// Start listening for speech. Returns transcribed text via callback.
  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    if (!_isInitialized) await init();
    if (!_isInitialized) return;

    _isListening = true;

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        if (result.finalResult) {
          _isListening = false;
          onResult(result.recognizedWords);
          onDone();
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        partialResults: false,
      ),
    );
  }

  /// Stop listening
  Future<void> stopListening() async {
    _isListening = false;
    await _speech.stop();
  }

  /// Speak text aloud
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
  }

  /// Stop speaking
  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  void dispose() {
    _speech.stop();
    _tts.stop();
  }
}
