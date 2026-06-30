import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent_action.dart';

class AiService {
  static const String _defaultBaseUrl = 'https://api.deepseek.com';
  static const String _defaultModel = 'deepseek-chat';

  // Free OpenRouter models tried in order when the current one is
  // rate-limited (429), out of credits (402), or erroring (502/503).
  // Only used automatically when the base URL points at OpenRouter.
  static const List<String> _freeFallbackModels = [
    'google/gemini-2.0-flash-exp:free',
    'meta-llama/llama-3.2-11b-vision-instruct:free',
    'qwen/qwen3-coder:free',
    'mistralai/mistral-small-3.1-24b-instruct:free',
    'google/gemma-3-27b-it:free',
  ];

  // Status codes worth retrying with a different free model.
  static const Set<int> _retryableStatusCodes = {402, 429, 502, 503};

  String? _apiKey;
  String _baseUrl = _defaultBaseUrl;
  String _model = _defaultModel;
  int _maxSteps = 15;
  bool _autoSwitchModels = true;
  String? _lastWorkingModel;
  final List<Map<String, String>> _conversationHistory = [];

  bool get autoSwitchModels => _autoSwitchModels;
  String? get lastWorkingModel => _lastWorkingModel;

  bool get _isOpenRouter => _baseUrl.contains('openrouter.ai');

  static const String _systemPrompt = '''
You are PrivateAgent, a helpful AI assistant that controls an Android phone. You can perform device actions and also have normal conversations.

When the user wants to perform a device action, you MUST respond with ONLY a JSON object (no markdown, no code fences, no extra text) in this exact format:
{"action": "action_name", "params": {"key": "value"}, "response": "What you say to the user"}

Available actions and their params:

SIMPLE ACTIONS (single step only):
- open_app: {"app_name": "YouTube"} - ONLY use this when the user JUST wants to open an app and nothing else
- make_call: {"contact_name": "Mom"} OR {"phone_number": "1234567890"} - Makes a phone call
- send_sms: {"contact_name": "John", "message": "Hello"} OR {"phone_number": "123", "message": "Hi"} - Sends SMS
- search_contact: {"query": "John"} - Searches contacts
- set_alarm: {"hour": 7, "minute": 30, "label": "Wake up"} - Sets an alarm
- set_volume: {"level": 50} - Sets volume (0-100)
- set_brightness: {"level": 50} - Sets brightness (0-100)
- read_screen: {} - Read what's currently on the screen
- press_back: {} - Press the back button

MULTI-STEP TASK (for anything that requires more than one action):
- execute_task: {"goal": "description of the full task"} - Automatically reads screen, taps, scrolls, types step by step

CRITICAL RULES:
1. If the user request contains "and" or involves MULTIPLE steps (open + search, open + send, open + find, etc.), you MUST use execute_task. NEVER use open_app for these.
2. execute_task handles everything: opening apps, finding elements, clicking, typing, scrolling.

Examples of when to use execute_task:
- "Create a new alarm for 7 AM" → execute_task with goal "Create a new alarm for 7 AM"
- "Go to YouTube and search for cats" → execute_task
- "Open WhatsApp and send hello to John" → execute_task
- "Open Settings and turn on WiFi" → execute_task
- "Search for restaurants on Google Maps" → execute_task

Examples of when to use open_app:
- "Open YouTube" → open_app (just opening, no further action)
- "Open Settings" → open_app (just opening)

For normal conversation (questions, chat, info requests), just respond with plain text naturally.
''';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString('api_key');
    _baseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
    _model = prefs.getString('api_model') ?? _defaultModel;
    _maxSteps = prefs.getInt('api_max_steps') ?? 15;
    _autoSwitchModels = prefs.getBool('auto_switch_models') ?? true;
  }

  Future<void> saveAutoSwitchModels(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    _autoSwitchModels = value;
    await prefs.setBool('auto_switch_models', value);
  }

  Future<void> saveSettings({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = apiKey;
    await prefs.setString('api_key', apiKey);

    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null && model.isNotEmpty) {
      _model = model;
      await prefs.setString('api_model', model);
    }
  }

  Future<void> saveMaxSteps(int steps) async {
    final prefs = await SharedPreferences.getInstance();
    _maxSteps = steps;
    await prefs.setInt('api_max_steps', steps);
  }

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;
  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey ?? '';
  int get maxSteps => _maxSteps;

  void clearHistory() {
    _conversationHistory.clear();
  }

  /// Send a message to the AI and get a response.
  Future<String> sendMessage(String message) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }

    // Add ONLY the text to the persistent conversation history to save tokens.
    _conversationHistory.add({
      'role': 'user',
      'content': message,
    });

    // Keep conversation history manageable (last 20 messages)
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    try {
      // Build the prompt including system instructions
      final messages = [
        {'role': 'system', 'content': _systemPrompt},
        ..._conversationHistory,
      ];

      // Build the list of models to try: current model first, then
      // (if enabled and on OpenRouter) the free fallback chain.
      final modelsToTry = <String>[_model];
      if (_autoSwitchModels && _isOpenRouter) {
        for (final m in _freeFallbackModels) {
          if (!modelsToTry.contains(m)) modelsToTry.add(m);
        }
      }

      http.Response? response;
      String? triedModel;
      Exception? lastError;

      for (final candidateModel in modelsToTry) {
        triedModel = candidateModel;
        try {
          response = await http.post(
            Uri.parse('$_baseUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_apiKey',
            },
            body: jsonEncode({
              'model': candidateModel,
              'messages': messages,
              'temperature': 0.7,
              'max_tokens': 1024,
            }),
          );
        } catch (e) {
          lastError = Exception('Network error: $e');
          continue; // try next model
        }

        if (response.statusCode == 200) {
          // Success — remember this model so we report which one worked.
          _lastWorkingModel = candidateModel;
          if (candidateModel != _model) {
            // Persist so next call starts with the model that's actually working.
            _model = candidateModel;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('api_model', candidateModel);
          }
          break;
        }

        if (_retryableStatusCodes.contains(response.statusCode)) {
          lastError = Exception(
            'API error (${response.statusCode}) on $candidateModel — trying next free model...',
          );
          response = null;
          continue; // try next model in the chain
        }

        // Non-retryable error (e.g. 401 bad key, 400 bad request) — stop here.
        break;
      }

      if (response == null) {
        throw lastError ?? Exception('All models failed.');
      }

      if (response.statusCode != 200) {
        Map<String, dynamic> errorBody = {};
        try {
          errorBody = jsonDecode(response.body);
        } catch (_) {}
        throw Exception(
          'API error (${response.statusCode}) on $triedModel: ${errorBody['error']?['message'] ?? response.body}',
        );
      }

      final data = jsonDecode(response.body);
      final assistantMessage =
          data['choices'][0]['message']['content'] as String;

      _conversationHistory.add({
        'role': 'assistant',
        'content': assistantMessage,
      });

      return assistantMessage;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  /// Parse the AI response to check if it's an action or plain text
  AgentAction? parseAction(String response) {
    // Try to parse as JSON action
    try {
      final trimmed = response.trim();
      // Handle if the response is wrapped in code fences
      String jsonStr = trimmed;
      if (trimmed.startsWith('```')) {
        final lines = trimmed.split('\n');
        lines.removeAt(0); // Remove opening fence
        if (lines.isNotEmpty && lines.last.trim() == '```') {
          lines.removeLast(); // Remove closing fence
        }
        jsonStr = lines.join('\n').trim();
      }

      if (jsonStr.startsWith('{') && jsonStr.contains('"action"')) {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        if (json.containsKey('action')) {
          return AgentAction.fromJson(json);
        }
      }
    } catch (_) {
      // Not JSON, it's plain text conversation
    }
    return null;
  }

  /// Fetches available models from the provider's /models endpoint
  Future<List<String>> fetchAvailableModels(String baseUrl, String apiKey) async {
    try {
      String cleanBaseUrl = baseUrl;
      // Many providers host it at /models, but some require the base URL without /chat/completions logic
      if (cleanBaseUrl.endsWith('/chat/completions')) {
        cleanBaseUrl = cleanBaseUrl.replaceAll('/chat/completions', '');
      }

      final response = await http.get(
        Uri.parse('$cleanBaseUrl/models'),
        headers: {
          'Authorization': 'Bearer $apiKey',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data.containsKey('data')) {
          final modelsList = data['data'] as List;
          return modelsList.map((m) => m['id'].toString()).toList();
        } else if (data is List) {
          return data.map((m) => m['id'].toString()).toList();
        }
      }
      return [];
    } catch (e) {
      print('Error fetching models: $e');
      return [];
    }
  }
}
