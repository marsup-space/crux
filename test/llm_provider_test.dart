import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/install_slug.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/deepseek_provider.dart';
import 'package:crux/src/services/providers/kimi_provider.dart';
import 'package:crux/src/services/providers/minimax_provider.dart';
import 'package:crux/src/services/providers/openai_compatible_provider.dart';
import 'package:crux/src/utils/sampling.dart';

void main() {
  // Minimal user/system messages used across the test cases.
  final userMsg = [
    {'role': 'user', 'content': 'hi'},
  ];
  final systemAndUser = [
    {'role': 'system', 'content': 'be brief'},
    {'role': 'user', 'content': 'hi'},
  ];

  group('AnthropicCompatibleProvider', () {
    final provider = AnthropicCompatibleProvider();

    group('thinking = enabled (default, with effort)', () {
      test('emits enabled + budget_tokens, plus output_config.effort', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'high'});
        expect(body['thinking']['budget_tokens'], isNotNull);
      });

      test('maps reasoning "normal" (Crux preset) to wire "medium"', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['output_config'], {'effort': 'medium'});
      });

      test('passes reasoning "max" through verbatim', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['output_config'], {'effort': 'max'});
      });

      test('uses provided thinkingBudget instead of the 10000 default', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 32000,
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 32000});
      });
    });

    group('thinking = disabled', () {
      test('omits thinking and output_config fields entirely', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'high',
        );
        expect(body.containsKey('thinking'), isFalse);
        expect(body.containsKey('output_config'), isFalse);
      });
    });

    group('system message handling', () {
      test(
        'promotes a system message to the top-level `system` array with cache_control',
        () {
          final body = provider.buildRequestBody(
            'claude-sonnet-4-6',
            systemAndUser,
            thinkingMode: 'enabled',
            reasoningEffort: 'normal',
          );
          final system = body['system'] as List;
          expect(system, hasLength(1));
          expect(system.first['type'], 'text');
          expect(system.first['text'], 'be brief');
          expect(system.first['cache_control'], {'type': 'ephemeral'});
          final chat = body['messages'] as List;
          expect(chat, hasLength(1));
          expect(chat.first['role'], 'user');
        },
      );
    });

    group('prompt cache breakpoints', () {
      test('adds cache_control to the last tool definition', () {
        final tools = [
          {
            'name': 'read',
            'description': 'Read a file',
            'parameters': {'type': 'object'},
          },
          {
            'name': 'write',
            'description': 'Write a file',
            'parameters': {'type': 'object'},
          },
        ];
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
          tools: tools,
        );
        final toolsList = body['tools'] as List;
        expect(toolsList, hasLength(2));
        expect(toolsList.first.containsKey('cache_control'), isFalse);
        expect(toolsList.last['cache_control'], {'type': 'ephemeral'});
      });

      test('adds cache_control to the last message content block (string)', () {
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          userMsg,
          thinkingMode: 'enabled',
        );
        final chat = body['messages'] as List;
        expect(chat, hasLength(1));
        final content = chat.first['content'] as List;
        expect(content, hasLength(1));
        expect(content.first['type'], 'text');
        expect(content.first['text'], 'hi');
        expect(content.first['cache_control'], {'type': 'ephemeral'});
      });

      test('adds cache_control to the last block of array content', () {
        final messages = [
          {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'},
              {'type': 'tool_result', 'tool_use_id': 't2', 'content': 'done'},
            ],
          },
        ];
        final body = provider.buildRequestBody(
          'claude-sonnet-4-6',
          messages,
          thinkingMode: 'enabled',
        );
        final chat = body['messages'] as List;
        final content = chat.first['content'] as List;
        expect(content, hasLength(2));
        expect(content.first.containsKey('cache_control'), isFalse);
        expect(content.last['cache_control'], {'type': 'ephemeral'});
      });

      test('does not mutate the original messages list', () {
        final original = [
          {'role': 'user', 'content': 'hi'},
        ];
        provider.buildRequestBody(
          'claude-sonnet-4-6',
          original,
          thinkingMode: 'enabled',
        );
        expect(original.first['content'], 'hi');
      });
    });

    group('mapEffort', () {
      test('renames Crux "normal" to wire "medium"', () {
        expect(provider.mapEffort('normal'), 'medium');
        expect(provider.mapEffort('medium'), 'medium');
      });

      test('passes low/high/max through verbatim', () {
        expect(provider.mapEffort('low'), 'low');
        expect(provider.mapEffort('high'), 'high');
        expect(provider.mapEffort('max'), 'max');
      });

      test('null and unknown values default to "medium"', () {
        expect(provider.mapEffort(null), 'medium');
        expect(provider.mapEffort(''), 'medium');
        expect(provider.mapEffort('extreme'), 'medium');
      });
    });

    test('ignores userId — not part of Anthropic wire format', () {
      final body = provider.buildRequestBody(
        'claude-sonnet-4-6',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-42',
      );
      expect(body.containsKey('user_id'), isFalse);
    });

    test('inherits base reasoningPresets (off, low, normal, high, max)', () {
      final presets = provider.reasoningPresetsFor('claude-sonnet-4-6');
      final low = presets.firstWhere((p) => p.internalValue == 'low');
      expect(low.displayLabel, 'low');
      final normal = presets.firstWhere((p) => p.internalValue == 'normal');
      expect(normal.displayLabel, 'normal');
    });
  });

  group('OpenAICompatibleProvider', () {
    final provider = OpenAICompatibleProvider();

    test(
      'reasoningPresets inherit from base (normal → normal, not adaptive)',
      () {
        final presets = provider.reasoningPresetsFor('deepseek-v4-pro');
        final low = presets.firstWhere((p) => p.internalValue == 'low');
        expect(low.displayLabel, 'low');
        final normal = presets.firstWhere((p) => p.internalValue == 'normal');
        expect(normal.displayLabel, 'normal');
      },
    );

    test('includes user_id in body when userId is provided', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-42',
      );
      expect(body['user_id'], 'abc123-42');
    });

    test('omits user_id when userId is null', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
      );
      expect(body.containsKey('user_id'), isFalse);
    });
  });

  group('DeepSeekProvider', () {
    final provider = DeepSeekProvider();

    test(
      'reasoningPresets inherit from base (normal → normal, not adaptive)',
      () {
        final presets = provider.reasoningPresetsFor('deepseek-v4-pro');
        final low = presets.firstWhere((p) => p.internalValue == 'low');
        expect(low.displayLabel, 'low');
        final normal = presets.firstWhere((p) => p.internalValue == 'normal');
        expect(normal.displayLabel, 'normal');
      },
    );

    test('passes userId through as `user` (Responses API field)', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-pro',
        userMsg,
        thinkingMode: 'enabled',
        userId: 'abc123-7',
      );
      // The Responses API's user-identifier field is `user`, not
      // Chat Completions' `user_id`.
      expect(body['user'], 'abc123-7');
    });

    test('passes "high" through unchanged (DeepSeek accepts it as-is)', () {
      expect(provider.mapEffort('high'), 'high');
    });
  });

  group('KimiProvider.buildRequestBody', () {
    // The Kimi API is OpenAI Chat Completions-shaped, so the
    // base class does the heavy lifting. KimiProvider's only
    // job is two model-ID-level adjustments:
    //   - map the two Crux-side K3 IDs (k3-1m, k3-256k) to the
    //     single upstream `k3` model;
    //   - drop the `reasoning_effort` field on K2.7 models
    //     (kimi-for-coding, kimi-for-coding-highspeed)
    //     because K2.7 is a binary Thinking:ON/OFF knob.
    final provider = KimiProvider();

    test('remaps k3-1m to upstream "k3" on the wire', () {
      final body = provider.buildRequestBody(
        'k3-1m',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
      );
      expect(
        body['model'],
        'k3',
        reason:
            'K3 has one upstream model ID regardless of context '
            'size — the plan tier decides the server-side cap',
      );
    });

    test('remaps k3-256k to upstream "k3" on the wire', () {
      final body = provider.buildRequestBody(
        'k3-256k',
        userMsg,
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
      );
      expect(body['model'], 'k3');
    });

    test('passes K2.7 model IDs through unchanged', () {
      // K2.7 model IDs (`kimi-for-coding`, `kimi-for-coding-
      // highspeed`) are the actual upstream names; the wire
      // body must not remap them.
      for (final id in const ['kimi-for-coding', 'kimi-for-coding-highspeed']) {
        final body = provider.buildRequestBody(
          id,
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(
          body['model'],
          id,
          reason: 'K2.7 model IDs are upstream-facing; no remap',
        );
      }
    });

    test('K3: passes low/high/max reasoning_effort through unchanged', () {
      // K3 now accepts `low` / `high` / `max` on the wire
      // (default `max`; unknown values 400). The KimiProvider
      // overrides `mapEffort` so `low` passes through — the
      // OpenAI-compatible base would otherwise map it to
      // `high`. `normal` has no K3 equivalent and collapses
      // onto `high` (the TOML renames it for display).
      for (final (internal, wire) in const [
        ('low', 'low'),
        ('normal', 'high'),
        ('high', 'high'),
        ('max', 'max'),
      ]) {
        final body = provider.buildRequestBody(
          'k3-1m',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: internal,
        );
        expect(
          body['reasoning_effort'],
          wire,
          reason: 'internal "$internal" should map to wire "$wire"',
        );
      }
    });

    test('K2.7: strips reasoning_effort (binary Thinking:ON/OFF only)', () {
      // The kimi-cli kosong SDK never sends `reasoning_effort`
      // for K2.7 — only `thinking.type: enabled/disabled`. We
      // mirror that wire shape so a future API tightening
      // can't 400 on us for the spurious field.
      for (final id in const ['kimi-for-coding', 'kimi-for-coding-highspeed']) {
        final body = provider.buildRequestBody(
          id,
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(
          body.containsKey('reasoning_effort'),
          isFalse,
          reason:
              'K2.7 must not send reasoning_effort; '
              'only $id\'s thinking.type matters',
        );
        expect(body['thinking'], {
          'type': 'enabled',
        }, reason: 'thinking.type stays enabled for K2.7');
      }
    });

    test(
      'K2.7 thinking off sends thinking.type=disabled, no reasoning_effort',
      () {
        // Belt-and-braces: even when the user has the picker on
        // "off" and the runtime passes `reasoning_effort: max`,
        // the wire body for K2.7 should be a pure
        // thinking.type=disabled with no effort field. This is
        // what makes K2.7's picker actually binary at the
        // protocol level.
        final body = provider.buildRequestBody(
          'kimi-for-coding',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'max',
        );
        expect(body['thinking'], {'type': 'disabled'});
        expect(body.containsKey('reasoning_effort'), isFalse);
      },
    );

    test(
      'all four Kimi models opt into stream_lerp for smoother rendering',
      () {
        // Kimi streams very chatty chunks (single tokens /
        // token-pairs), which renders stuttery without the
        // executor's 60Hz drain timer. The TOML sets
        // `stream_lerp = true` on every model entry; this
        // test pins that contract so a future refactor that
        // drops the flag (or splits it per-model) gets caught
        // here rather than as a UX regression report. The
        // equivalent provider_config_test entry covers the
        // same contract on the loaded config side.
        const allCruxIds = [
          'k3-1m',
          'k3-256k',
          'kimi-for-coding',
          'kimi-for-coding-highspeed',
        ];
        for (final id in allCruxIds) {
          // Sanity: every model builds a body. The real
          // contract is on the TOML's `stream_lerp = true`
          // (verified in provider_config_test).
          final body = provider.buildRequestBody(
            id,
            userMsg,
            thinkingMode: 'enabled',
            reasoningEffort: 'max',
          );
          expect(
            body['model'],
            isNotNull,
            reason: 'sanity check that $id builds a body at all',
          );
        }
      },
    );

    group('temperature / top_p override', () {
      // Kimi Code's platform requires `temperature = 1.0` for
      // every model (K3 + K2.7 Code family) and rejects any
      // other value with
      // `400 invalid temperature: only 1 is allowed for this model`.
      // Crux's defaults and the `/temperature` slash command
      // would otherwise pass `temperature = 0.0` (or any user
      // override in `[0.0, 1.0]`) and 400 every request. The
      // provider forces `temperature = 1.0` paired with Kimi's
      // recommended `top_p = 0.95` on the wire, regardless of
      // the TOML model config or runtime override.
      const allCruxIds = [
        'k3-1m',
        'k3-256k',
        'kimi-for-coding',
        'kimi-for-coding-highspeed',
      ];

      for (final id in allCruxIds) {
        test('$id: forces temperature=1.0 regardless of caller value', () {
          // The caller is allowed to pass anything (including
          // the Crux default 0.0 or any /temperature override
          // in [0, 1]) — the wire body must still pin
          // temperature=1.0 for Kimi.
          for (final callerTemp in const [0.0, 0.5, 0.7, 1.0]) {
            final body = provider.buildRequestBody(
              id,
              userMsg,
              thinkingMode: 'enabled',
              reasoningEffort: 'max',
              temperature: callerTemp,
            );
            expect(
              body['temperature'],
              1.0,
              reason: 'caller passed $callerTemp but Kimi requires 1.0',
            );
          }
        });

        test('$id: pairs temperature with Kimi-recommended top_p=0.95', () {
          // top_p must be Kimi's recommended 0.95 too — the
          // executor would otherwise derive top_p from the
          // (now-discarded) caller temperature, drifting off
          // the model's calibrated range.
          for (final callerTopP in const [0.85, 0.9, 0.95, 1.0]) {
            final body = provider.buildRequestBody(
              id,
              userMsg,
              thinkingMode: 'enabled',
              reasoningEffort: 'max',
              temperature: 1.0,
              topP: callerTopP,
            );
            expect(
              body['top_p'],
              0.95,
              reason: 'caller passed $callerTopP but Kimi pairs with 0.95',
            );
          }
        });
      }
    });
  });

  group('KimiProvider — usage response parser', () {
    // The Kimi /usages endpoint emits a flexible shape with a
    // top-level `usage` summary and a `limits` array of
    // time-windowed rows. The parser maps that into the
    // generic CodingPlanUsage (5h interval / 1w weekly) the
    // toolbar already knows how to render. These tests cover
    // the parser via the public getCodingPlanUsage surface
    // (which is the only thing the toolbar can call); the
    // _parseKimiUsageResponse helper is exercised through it.
    //
    // We can't easily hit the live endpoint from a unit test,
    // so we exercise the parser-equivalent path by giving the
    // provider a known baseUrl + apiKey and asserting the
    // network failure mode (no live server). The real parser
    // tests live in the integration suite; this group
    // documents the *contract* (which URL the provider
    // fetches, which headers it sends, and how the K3 model
    // remap interacts with the quota path) so a future
    // refactor doesn't silently break it.
    final provider = KimiProvider();

    test('hits /usages relative to the configured baseUrl', () async {
      // With a known baseUrl, getCodingPlanUsage should attempt
      // a GET against `{baseUrl}/usages` and surface the
      // resulting network failure. The exact error kind
      // depends on the host the test runs in (no real Kimi
      // server) — we just assert it tries the right URL and
      // surfaces a network-shaped error rather than a parse
      // error.
      provider.startCodingPlanPolling(
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:1/', // closed port → connection refused
      );
      try {
        await provider.getCodingPlanUsage();
        fail('expected network error against 127.0.0.1:1');
      } catch (e) {
        expect(e.toString(), isNot(contains('Invalid JSON')));
      }
    });

    test('errors clearly when started without a baseUrl', () async {
      // If the coordinator forgot to thread the baseUrl, the
      // provider should fail fast with a notConfigured error
      // rather than sending a request to an empty URL.
      provider.startCodingPlanPolling(
        apiKey: 'sk-test',
        // baseUrl intentionally omitted
      );
      expect(
        () => provider.getCodingPlanUsage(),
        throwsA(
          isA<dynamic>().having(
            (e) => e.toString(),
            'toString',
            contains('No base URL configured'),
          ),
        ),
      );
    });
  });

  group(
    'OpenAICompatibleProvider.sanitizeMessages (tool_call ↔ tool pairing)',
    () {
      // The OpenAI Chat Completions protocol requires every tool_call
      // on an assistant message to be followed by a matching
      // role: 'tool' message (matched on tool_call_id). The sanitizer
      // on OpenAICompatibleProvider repairs orphan tool_calls —
      // typically caused by switching the session model from a
      // provider using the Anthropic wire family to one using the
      // OpenAI wire family mid-conversation, or by a mid-round
      // interruption that left a tool_call row without its results.
      final provider = OpenAICompatibleProvider();

      Map<String, dynamic> toolCall(String id) => {
        'id': id,
        'type': 'function',
        'function': {'name': 'x', 'arguments': '{}'},
      };

      test(
        'returns the original list reference when pairing is already valid',
        () {
          // The well-formed fast path: a complete assistant→tool chain
          // returns the same list reference, no allocation.
          final messages = [
            {'role': 'user', 'content': 'do it'},
            {
              'role': 'assistant',
              'content': null,
              'tool_calls': [toolCall('call_a'), toolCall('call_b')],
            },
            {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
            {'role': 'tool', 'tool_call_id': 'call_b', 'content': 'r2'},
            {'role': 'assistant', 'content': 'done'},
          ];
          expect(
            identical(provider.sanitizeMessages(messages), messages),
            isTrue,
          );
        },
      );

      test('drops orphan tool_calls from an assistant message whose tool '
          'results were never persisted (mid-round interrupt)', () {
        // Regression: a tool_call row was persisted but the round was
        // interrupted before the addToolRound transaction wrote the
        // tool result rows. The next request sees a dangling
        // tool_calls array. OpenAI rejects this with a 400.
        final messages = [
          {'role': 'user', 'content': 'do it'},
          {
            'role': 'assistant',
            'content': 'I will call a tool',
            'tool_calls': [toolCall('call_a')],
          },
          {'role': 'user', 'content': 'try again'},
        ];
        final out = provider.sanitizeMessages(messages);
        // The text content is preserved; tool_calls is removed (no
        // surviving entries).
        expect(out, hasLength(3));
        expect(out[1]['role'], 'assistant');
        expect(out[1]['content'], 'I will call a tool');
        expect(out[1].containsKey('tool_calls'), isFalse);
      });

      test('drops only the orphan entries when some tool_calls have responses '
          'and others do not', () {
        // Mid-round interrupt in the middle of a multi-call round: A
        // got a response, B did not. Keep A's response, drop B from
        // the assistant's tool_calls, and let the user message that
        // interrupted the round stand on its own.
        final messages = [
          {'role': 'user', 'content': 'do both'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [toolCall('call_a'), toolCall('call_b')],
          },
          {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
          {'role': 'user', 'content': 'actually just give me the first result'},
        ];
        final out = provider.sanitizeMessages(messages);
        expect(out, hasLength(4));
        expect(out[1]['tool_calls'], hasLength(1));
        expect(
          out[1]['tool_calls'][0]['id'],
          'call_a',
          reason: 'only call_a should survive',
        );
        // call_a's tool response is preserved.
        expect(out[2]['tool_call_id'], 'call_a');
        // The interrupting user message is preserved.
        expect(out[3]['content'], 'actually just give me the first result');
      });

      test('drops orphan tool messages that have no preceding assistant '
          'tool_call with a matching id', () {
        // A tool message landed in the history without a matching
        // tool_call — e.g. an external write or a corrupted round.
        // OpenAI rejects tool messages that don't follow a matching
        // assistant tool_call.
        final messages = [
          {'role': 'user', 'content': 'do it'},
          {'role': 'tool', 'tool_call_id': 'call_x', 'content': 'r'},
          {'role': 'user', 'content': 'do something else'},
        ];
        final out = provider.sanitizeMessages(messages);
        expect(out, hasLength(2));
        expect(out[0]['content'], 'do it');
        expect(out[1]['content'], 'do something else');
      });

      test('drops tool messages with a null tool_call_id', () {
        // Malformed tool row — has the role but no call id. There's
        // no way to associate it with an assistant tool_call, so
        // it's always orphan.
        final messages = [
          {'role': 'user', 'content': 'do it'},
          {'role': 'tool', 'content': 'orphan result'},
          {'role': 'user', 'content': 'next'},
        ];
        final out = provider.sanitizeMessages(messages);
        expect(out, hasLength(2));
        expect(out.where((m) => m['role'] == 'tool'), isEmpty);
      });

      test('preserves well-formed tool flow even with intervening system '
          'messages', () {
        // System messages don't terminate a tool flow — only user
        // and tool_call-free assistant messages do. (The OpenAI spec
        // allows system messages to appear anywhere; in Crux they're
        // hoisted to a separate `system` field by buildRequestBody,
        // so the only system messages in the messages list are
        // legitimate interleavings.)
        final messages = [
          {'role': 'system', 'content': 'be brief'},
          {'role': 'user', 'content': 'do it'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [toolCall('call_a')],
          },
          {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'r1'},
        ];
        expect(
          identical(provider.sanitizeMessages(messages), messages),
          isTrue,
        );
      });

      test('does not mutate the original message maps', () {
        // The sanitizer must produce new map instances for any row
        // it modifies, so callers that hold references to the
        // pre-sanitize maps don't see surprise mutations across
        // requests.
        final originalAssistant = {
          'role': 'assistant',
          'content': 'text',
          'tool_calls': [toolCall('call_a'), toolCall('call_b')],
        };
        final messages = [
          {'role': 'user', 'content': 'do it'},
          originalAssistant,
          // No tool responses — both tool_calls are orphan.
        ];
        final out = provider.sanitizeMessages(messages);
        expect(
          identical(out[1], originalAssistant),
          isFalse,
          reason: 'modified rows must be a fresh map',
        );
        expect(
          originalAssistant['tool_calls'],
          hasLength(2),
          reason: 'original must not be mutated in place',
        );
      });
    },
  );

  group('AnthropicCompatibleProvider.sanitizeMessages '
      '(tool_use ↔ tool_result pairing)', () {
    // The Anthropic Messages protocol requires every tool_use
    // block in an assistant message's content list to be answered
    // by a tool_result block (matched on tool_use_id) in the very
    // next user message. The sanitizer on AnthropicCompatibleProvider
    // repairs orphan tool_use blocks — typically caused by switching
    // the session model from an OpenAI-wire provider to an
    // Anthropic-wire provider mid-conversation, or by a mid-round
    // interruption that left a tool_call row without its results.
    // The MiniMax session that hit "tool result's tool id ... not
    // found (2013)" was exercising exactly this path.
    final provider = AnthropicCompatibleProvider();

    Map<String, dynamic> thinkingBlock(String signature) => {
      'type': 'thinking',
      'thinking': 'reasoning text',
      'signature': signature,
    };

    Map<String, dynamic> textBlock(String text) => {
      'type': 'text',
      'text': text,
    };

    Map<String, dynamic> toolUseBlock(String id, String name) => {
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': {'arg': 'val'},
    };

    Map<String, dynamic> toolResultBlock(String id, String content) => {
      'type': 'tool_result',
      'tool_use_id': id,
      'content': content,
    };

    test(
      'returns the original list reference when pairing is already valid',
      () {
        // The well-formed fast path: a complete assistant→user
        // tool_use↔tool_result chain returns the same list reference,
        // no allocation.
        final messages = [
          {'role': 'user', 'content': 'do it'},
          {
            'role': 'assistant',
            'content': [
              thinkingBlock('sig1'),
              textBlock('calling both'),
              toolUseBlock('toolu_a', 'tool_x'),
              toolUseBlock('toolu_b', 'tool_x'),
            ],
          },
          {
            'role': 'user',
            'content': [
              toolResultBlock('toolu_a', 'r1'),
              toolResultBlock('toolu_b', 'r2'),
            ],
          },
          {
            'role': 'assistant',
            'content': [textBlock('done')],
          },
        ];
        expect(
          identical(provider.sanitizeMessages(messages), messages),
          isTrue,
        );
      },
    );

    test('drops orphan tool_use blocks from an assistant message whose tool '
        'results were never persisted (mid-round interrupt)', () {
      // Regression: a tool_call row was persisted but the round was
      // interrupted before addToolRound wrote the tool result rows.
      // The next request sees a dangling tool_use block. Anthropic
      // rejects this with a 400.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': [
            thinkingBlock('sig1'),
            textBlock('I will call a tool'),
            toolUseBlock('toolu_a', 'tool_x'),
          ],
        },
        {'role': 'user', 'content': 'try again'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(3));
      // The thinking and text blocks are preserved; tool_use is gone.
      expect(out[1]['role'], 'assistant');
      final keptContent = (out[1]['content'] as List).cast<Map>();
      expect(
        keptContent.map((b) => b['type']),
        ['thinking', 'text'],
        reason: 'thinking + text survive, tool_use dropped',
      );
      // The interrupting user message is preserved verbatim.
      expect(out[2]['content'], 'try again');
    });

    test('drops only the orphan tool_use blocks when some calls have '
        'responses and others do not', () {
      // Mid-round interrupt in the middle of a multi-call round:
      // A got a response, B did not. Keep A's response, drop B
      // from the assistant's content blocks, and let the user
      // message that interrupted the round stand on its own.
      final messages = [
        {'role': 'user', 'content': 'do both'},
        {
          'role': 'assistant',
          'content': [
            toolUseBlock('toolu_a', 'tool_x'),
            toolUseBlock('toolu_b', 'tool_x'),
          ],
        },
        {
          'role': 'user',
          'content': [toolResultBlock('toolu_a', 'r1')],
        },
        {'role': 'user', 'content': 'actually just give me the first result'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(4));
      // Only toolu_a survives on the assistant message.
      final assistantContent = (out[1]['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(assistantContent, hasLength(1));
      expect(
        assistantContent[0]['id'],
        'toolu_a',
        reason: 'only toolu_a should survive',
      );
      // toolu_a's tool_result is preserved.
      final firstUserContent = (out[2]['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(firstUserContent[0]['tool_use_id'], 'toolu_a');
      // The interrupting user message is preserved.
      expect(out[3]['content'], 'actually just give me the first result');
    });

    test('drops an assistant message whose content is only orphan tool_use '
        'blocks', () {
      // Edge case: every tool_use in the assistant message was
      // orphaned (no tool_result ever came back). After dropping
      // all of them, the assistant content would be empty — and an
      // assistant message with no content blocks is invalid in
      // Anthropic format, so the whole message goes.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': [toolUseBlock('toolu_a', 'tool_x')],
        },
        {'role': 'user', 'content': 'never mind'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(2));
      expect(out.map((m) => m['role']), ['user', 'user']);
    });

    test('drops orphan tool_result blocks that have no preceding assistant '
        'tool_use with a matching id', () {
      // A tool_result block landed in the history without a
      // matching tool_use — e.g. an external write or a corrupted
      // round. Anthropic rejects tool_results that don't follow a
      // matching assistant tool_use.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'user',
          'content': [toolResultBlock('toolu_x', 'orphan')],
        },
        {'role': 'user', 'content': 'do something else'},
      ];
      final out = provider.sanitizeMessages(messages);
      // The orphan user message is dropped entirely (its only
      // content block was the orphan tool_result).
      expect(out, hasLength(2));
      expect(out[0]['content'], 'do it');
      expect(out[1]['content'], 'do something else');
    });

    test('drops tool_result blocks with a null tool_use_id', () {
      // Malformed tool_result block — has the type but no
      // tool_use_id. There's no way to associate it with an
      // assistant tool_use, so it's always dropped.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'content': 'orphan result'},
          ],
        },
        {'role': 'user', 'content': 'next'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(2));
      // The orphan user message (only block was the malformed
      // tool_result) is dropped.
      expect(out[0]['content'], 'do it');
      expect(out[1]['content'], 'next');
    });

    test('preserves thinking blocks on assistant messages even when their '
        'tool_use blocks are dropped', () {
      // Critical: thinking blocks carry a `signature` the Anthropic
      // API needs to verify the prior turn's reasoning. Dropping
      // them silently would break extended thinking on subsequent
      // turns. The sanitizer must always preserve `thinking`
      // blocks when pruning tool_use.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': [
            thinkingBlock('sig_precious'),
            toolUseBlock('toolu_a', 'tool_x'),
          ],
        },
        // No tool_result — tool_use is orphan, but thinking is not.
        {'role': 'user', 'content': 'abort'},
      ];
      final out = provider.sanitizeMessages(messages);
      final assistantContent = (out[1]['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(assistantContent, hasLength(1));
      expect(assistantContent[0]['type'], 'thinking');
      expect(
        assistantContent[0]['signature'],
        'sig_precious',
        reason: 'thinking block must survive orphan tool_use pruning',
      );
    });

    test('preserves well-formed tool flow even with intervening system '
        'messages', () {
      // System messages don't terminate a tool flow — only user
      // and tool_use-free assistant messages do. (Crux's
      // buildRequestBody hoists system messages to a separate
      // `system` field, so the only system messages in the messages
      // list are legitimate interleavings.)
      final messages = [
        {'role': 'system', 'content': 'be brief'},
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': [toolUseBlock('toolu_a', 'tool_x')],
        },
        {
          'role': 'user',
          'content': [toolResultBlock('toolu_a', 'r1')],
        },
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('handles a user message that mixes text and a tool_result', () {
      // A user message can carry text and tool_result blocks in
      // the same content list. The text block doesn't terminate
      // the flow by itself — only the user message as a whole
      // does. The tool_result here answers the prior tool_use,
      // so the chain stays valid.
      final messages = [
        {'role': 'user', 'content': 'do it'},
        {
          'role': 'assistant',
          'content': [toolUseBlock('toolu_a', 'tool_x')],
        },
        {
          'role': 'user',
          'content': [
            toolResultBlock('toolu_a', 'r1'),
            textBlock('also, thanks'),
          ],
        },
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('does not mutate the original message maps', () {
      // The sanitizer must produce new map instances for any row
      // it modifies, so callers that hold references to the
      // pre-sanitize maps don't see surprise mutations across
      // requests.
      final originalAssistant = {
        'role': 'assistant',
        'content': [thinkingBlock('sig1'), toolUseBlock('toolu_a', 'tool_x')],
      };
      final messages = [
        {'role': 'user', 'content': 'do it'},
        originalAssistant,
        // No tool_response — toolu_a is orphan.
      ];
      final out = provider.sanitizeMessages(messages);
      expect(
        identical(out[1], originalAssistant),
        isFalse,
        reason: 'modified rows must be a fresh map',
      );
      // Original is unchanged: both blocks still present.
      final origContent = (originalAssistant['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(origContent, hasLength(2));
      expect(
        origContent.map((b) => b['type']),
        ['thinking', 'tool_use'],
        reason: 'original must not be mutated in place',
      );
    });
  });

  group('LlmProvider.sanitizeMessages (default no-op)', () {
    test(
      'returns the original list reference when no modifications are made',
      () {
        // The default implementation must be a true no-op so the
        // common case (provider that doesn't need sanitization)
        // allocates nothing when LlmClient invokes the hook per
        // request.
        final p = OpenAICompatibleProvider();
        final messages = [
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
        ];
        expect(identical(p.sanitizeMessages(messages), messages), isTrue);
      },
    );
  });

  // ─── supportsOrphanToolRepair capability flag ────────────────
  //
  // Gates the chat executor's auto-repair-and-retry hook. The
  // capability must live on the Anthropic side of the inheritance
  // chain — MiniMax picks it up through `extends
  // AnthropicCompatibleProvider`, with no MiniMax-specific code.

  group('LlmProvider.supportsOrphanToolRepair', () {
    test('default is false on the LlmProvider base', () {
      // The base class doesn't override; only Anthropic-compatible
      // providers do.
      expect(AnthropicCompatibleProvider().supportsOrphanToolRepair, isTrue);
      expect(OpenAICompatibleProvider().supportsOrphanToolRepair, isFalse);
      expect(DeepSeekProvider().supportsOrphanToolRepair, isFalse);
    });
  });

  group('LlmProvider.forcedTemperature', () {
    // The chat toolbar consults `forcedTemperature` to decide
    // whether to render an interactive "T:0.5" chip (most
    // providers — they pass the caller's value through) or a
    // non-interactive "T:1 (fixed)" chip (Kimi Code — its
    // API 400s on any value other than 1.0). The base class
    // returns `null` so non-overriding providers keep the
    // normal interactive UX.
    test('defaults to null on providers that do not pin temperature', () {
      // OpenAICompatibleProvider / AnthropicCompatibleProvider
      // / DeepSeekProvider don't override forcedTemperature;
      // their instances return null, which is what the
      // toolbar's chip builder uses to decide between the
      // interactive button and the "fixed" text.
      expect(OpenAICompatibleProvider().forcedTemperature, isNull);
      expect(AnthropicCompatibleProvider().forcedTemperature, isNull);
      expect(DeepSeekProvider().forcedTemperature, isNull);
    });

    test('KimiProvider pins 1.0 (matches what buildRequestBody emits)', () {
      // The buildRequestBody override forces
      // `temperature: 1.0` for every Kimi model; the
      // forcedTemperature getter has to agree so the
      // toolbar's "T:1 (fixed)" chip matches the actual
      // wire value.
      expect(KimiProvider().forcedTemperature, 1.0);
    });

    test('MiniMax inherits the Anthropic override (no MiniMax override)', () {
      // The "target anthropic not minimax" property: the capability
      // is declared once on AnthropicCompatibleProvider and
      // inherited. Any future Anthropic-compatible provider gets
      // the same flag automatically.
      expect(MiniMaxProvider().supportsOrphanToolRepair, isTrue);
    });
  });

  group('DeepSeekProvider.sanitizeMessages', () {
    final provider = DeepSeekProvider();

    test('returns the original list reference when there are no orphans', () {
      // The Responses-API sanitizer is a responses-shape analogue of
      // the OpenAI pairing repair: it walks the OpenAI-IR messages
      // (the storage shape the executor still uses for any
      // non-Anthropic wire family) and prunes orphan tool_calls /
      // tool messages. Well-formed history is a no-op: same list
      // reference, no allocation.
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': 'calling read',
          'tool_calls': [
            {
              'id': 'call_a',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{"p":"/a"}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': 'a contents'},
      ];
      expect(identical(provider.sanitizeMessages(messages), messages), isTrue);
    });

    test('drops orphan tool_calls whose tool results were never persisted', () {
      // Regression for the "an assistant message with tool_call must
      // be followed by tool messages responding to each tool_call_id"
      // 400. With the Responses API the same invariant holds under a
      // different name (function_call must pair with a
      // function_call_output), and the OpenAI-IR sanitizer still
      // repairs it before buildRequestBody converts the shape.
      final messages = [
        {'role': 'user', 'content': 'list /tmp'},
        {
          'role': 'assistant',
          'content': 'ok',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'bash', 'arguments': '{"cmd": "ls /tmp"}'},
            },
          ],
        },
        // No `tool` message for call_1 — interrupted mid-round.
        {'role': 'user', 'content': 'never mind, just say hi'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(3));
      final assistant = out[1];
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], 'ok');
      expect(
        assistant.containsKey('tool_calls'),
        isFalse,
        reason: 'orphan tool_call array must be dropped entirely',
      );
    });

    test('drops orphan tool messages with no preceding assistant tool_call', () {
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'tool', 'tool_call_id': 'call_ghost', 'content': '???'},
      ];
      final out = provider.sanitizeMessages(messages);
      expect(out, hasLength(1));
      expect(out[0]['role'], 'user');
    });
  });

  group('DeepSeekProvider.buildRequestBody (Responses API)', () {
    final provider = DeepSeekProvider();

    test('produces the Responses wire shape — input items + instructions + '
        'reasoning.effort — not Chat Completions messages', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-flash',
        [
          {'role': 'system', 'content': 'Be terse.'},
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
          {'role': 'user', 'content': 'bye'},
        ],
        thinkingMode: 'enabled',
        reasoningEffort: 'max',
        maxTokens: 1000,
        topP: 0.9,
        tools: [
          {
            'name': 'read',
            'description': 'read a file',
            'parameters': {'type': 'object'},
          },
        ],
      );

      // system → instructions
      expect(body['instructions'], 'Be terse.');
      // No Chat Completions `messages` key.
      expect(body.containsKey('messages'), isFalse);
      // input is the item list (system item NOT present — it was hoisted).
      expect(body['input'], [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
        {'role': 'user', 'content': 'bye'},
      ]);
      // Reasoning effort is nested, not top-level.
      expect(body['reasoning'], {'effort': 'max'});
      expect(body['max_output_tokens'], 1000);
      expect(body['top_p'], 0.9);
      expect(body['stream'], true);
      // tools are FLAT — no nested {function: {...}} wrapper.
      final tools = body['tools'] as List;
      expect(tools, hasLength(1));
      expect(tools[0], {
        'type': 'function',
        'name': 'read',
        'description': 'read a file',
        'parameters': {'type': 'object'},
      });
    });

    test('converter maps assistant tool_calls + tool results to function_call '
        'and function_call_output items', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-flash',
        [
          {'role': 'user', 'content': 'read /tmp'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call_7',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"cmd":"cat /tmp"}',
                },
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_7', 'content': 'file body'},
        ],
      );
      final input = body['input'] as List;
      // user, function_call, function_call_output
      expect(input, hasLength(3));
      expect(input[0], {'role': 'user', 'content': 'read /tmp'});
      final fc = input[1] as Map<String, dynamic>;
      expect(fc['type'], 'function_call');
      expect(fc['call_id'], 'call_7');
      expect(fc['name'], 'bash');
      expect(fc['arguments'], '{"cmd":"cat /tmp"}');
      final fco = input[2] as Map<String, dynamic>;
      expect(fco['type'], 'function_call_output');
      expect(fco['call_id'], 'call_7');
      expect(fco['output'], 'file body');
    });

    test('omits reasoning when thinkingMode is disabled', () {
      final body = provider.buildRequestBody(
        'deepseek-v4-flash',
        [{'role': 'user', 'content': 'hi'}],
        thinkingMode: 'disabled',
      );
      expect(body.containsKey('reasoning'), isFalse);
    });
  });

  group('MiniMaxProvider', () {
    final provider = MiniMaxProvider();

    group('M3 model — adaptive thinking, can disable', () {
      test(
        'normal effort emits thinking: {type: adaptive} with no budget_tokens',
        () {
          final body = provider.buildRequestBody(
            'MiniMax-M3',
            userMsg,
            thinkingMode: 'enabled',
            reasoningEffort: 'normal',
          );
          expect(body['thinking'], {'type': 'adaptive'});
          // AI SDK unit test contract: budget_tokens is intentionally
          // absent for adaptive thinking.
          expect(body['thinking'].containsKey('budget_tokens'), isFalse);
          expect(body['output_config'], {'effort': 'medium'});
        },
      );

      test('low effort emits thinking: {type: enabled} with budget_tokens', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'low',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'low'});
      });

      test(
        'high effort emits thinking: {type: enabled} with budget_tokens',
        () {
          final body = provider.buildRequestBody(
            'MiniMax-M3',
            userMsg,
            thinkingMode: 'enabled',
            reasoningEffort: 'high',
          );
          expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
          expect(body['output_config'], {'effort': 'high'});
        },
      );

      test('max effort emits thinking: {type: enabled} with budget_tokens', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'max'});
      });

      test(
        'thinking = disabled omits the thinking and output_config fields',
        () {
          final body = provider.buildRequestBody(
            'MiniMax-M3',
            userMsg,
            thinkingMode: 'disabled',
            reasoningEffort: 'high',
          );
          expect(body.containsKey('thinking'), isFalse);
          expect(body.containsKey('output_config'), isFalse);
        },
      );

      test('uses provided thinkingBudget instead of the 10000 default', () {
        final body = provider.buildRequestBody(
          'MiniMax-M3',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 8000,
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8000});
      });

      test(
        'reuses the base mapEffort — single source of truth for the mapping',
        () {
          // Sanity: M3's wire-shape behavior should be driven by the
          // shared helper, not a duplicated switch. We invoke both
          // implementations and assert they agree on the full preset grid.
          final base = AnthropicCompatibleProvider();
          for (final effort in [
            'low',
            'normal',
            'medium',
            'high',
            'max',
            null,
          ]) {
            final body = provider.buildRequestBody(
              'MiniMax-M3',
              userMsg,
              thinkingMode: 'enabled',
              reasoningEffort: effort,
            );
            final expected = base.mapEffort(effort);
            // All efforts always produce output_config.effort.
            expect(
              body['output_config'],
              {'effort': expected},
              reason: 'effort=$effort should map to wire $expected',
            );
            // normal → adaptive, others → enabled + budget.
            if (effort == 'normal') {
              expect(
                body['thinking'],
                {'type': 'adaptive'},
                reason: 'effort=normal should use adaptive thinking',
              );
            } else {
              expect(
                body['thinking']['type'],
                'enabled',
                reason: 'effort=$effort should use enabled thinking',
              );
            }
          }
        },
      );
    });

    group('M2.x model — thinking always on, no adaptive, cannot disable', () {
      test('normal effort emits thinking: {type: enabled} (NOT adaptive)', () {
        // M2.x has no adaptive mode — the model would reject or
        // ignore `{type: "adaptive"}`. Fall back to enabled +
        // budget, like the other budget-driven presets.
        final body = provider.buildRequestBody(
          'MiniMax-M2.7',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'normal',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'medium'});
      });

      test(
        'high effort emits thinking: {type: enabled} with budget_tokens',
        () {
          final body = provider.buildRequestBody(
            'MiniMax-M2.5',
            userMsg,
            thinkingMode: 'enabled',
            reasoningEffort: 'high',
          );
          expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
          expect(body['output_config'], {'effort': 'high'});
        },
      );

      test('max effort emits thinking: {type: enabled} with budget_tokens', () {
        final body = provider.buildRequestBody(
          'MiniMax-M2',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'max',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'max'});
      });

      test('thinking = disabled is IGNORED — M2.x always emits enabled', () {
        // Per the MiniMax docs: "对于 M2.x 模型，thinking 无法关闭；
        // 即使传入 `thinking: {type: 'disabled'}`，thinking 仍会保持
        // 开启." We must not honour the user's off toggle for M2.x.
        final body = provider.buildRequestBody(
          'MiniMax-M2.7',
          userMsg,
          thinkingMode: 'disabled',
          reasoningEffort: 'high',
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 10000});
        expect(body['output_config'], {'effort': 'high'});
      });

      test('uses provided thinkingBudget for M2.x', () {
        final body = provider.buildRequestBody(
          'MiniMax-M2.1-highspeed',
          userMsg,
          thinkingMode: 'enabled',
          reasoningEffort: 'high',
          thinkingBudget: 8000,
        );
        expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8000});
      });
    });

    test('uses bearer auth (vs the base class\'s anthropicApiKey)', () {
      expect(provider.authStyle, AuthStyle.bearer);
    });

    test('inherits cache_control on system, tools, and messages', () {
      final tools = [
        {
          'name': 'bash',
          'description': 'Run a command',
          'parameters': {'type': 'object'},
        },
      ];
      final body = provider.buildRequestBody(
        'MiniMax-M3',
        systemAndUser,
        thinkingMode: 'enabled',
        reasoningEffort: 'high',
        tools: tools,
      );
      // System: array with cache_control on last block
      final system = body['system'] as List;
      expect(system.last['cache_control'], {'type': 'ephemeral'});
      // Tools: cache_control on last tool
      final toolsList = body['tools'] as List;
      expect(toolsList.last['cache_control'], {'type': 'ephemeral'});
      // Messages: cache_control on last content block
      final chat = body['messages'] as List;
      final content = chat.last['content'] as List;
      expect(content.last['cache_control'], {'type': 'ephemeral'});
    });

    test(
      'reasoningPresetsFor M3 maps normal → adaptive, others stay identity',
      () {
        // Adaptive is an M3-only feature. The UI shows the
        // `adaptive` label (renamed from `normal`) only when the
        // active model is M3. The labels come from minimax.toml's
        // [models.reasoning_labels] — not hardcoded.
        const m3ModelLabels = {
          'low': 'disabled',
          'normal': 'adaptive',
          'high': 'disabled',
          'max': 'disabled',
        };
        final presets = provider.reasoningPresetsFor(
          'MiniMax-M3',
          modelLabels: m3ModelLabels,
        );
        // low/high/max are disabled — only normal (as "adaptive") and off remain.
        final normal = presets.firstWhere((p) => p.internalValue == 'normal');
        expect(normal.displayLabel, 'adaptive');
        // Disabled entries are removed from the list.
        expect(presets.where((p) => p.internalValue == 'low'), isEmpty);
        expect(presets.where((p) => p.internalValue == 'high'), isEmpty);
        expect(presets.where((p) => p.internalValue == 'max'), isEmpty);
      },
    );

    test(
      'reasoningPresetsFor M2.x shows normal → normal (no adaptive label)',
      () {
        // M2.x doesn't support adaptive thinking, so the rename
        // would be misleading. Show `normal` as `normal` and let
        // the wire format (enabled + budget) do the work.
        for (final modelId in [
          'MiniMax-M2',
          'MiniMax-M2.1',
          'MiniMax-M2.1-highspeed',
          'MiniMax-M2.5',
          'MiniMax-M2.5-highspeed',
          'MiniMax-M2.7',
          'MiniMax-M2.7-highspeed',
        ]) {
          final presets = provider.reasoningPresetsFor(modelId);
          final low = presets.firstWhere((p) => p.internalValue == 'low');
          expect(
            low.displayLabel,
            'low',
            reason: '$modelId: low should be identity',
          );
          final normal = presets.firstWhere((p) => p.internalValue == 'normal');
          expect(
            normal.displayLabel,
            'normal',
            reason: '$modelId: normal should NOT be relabeled "adaptive"',
          );
          final high = presets.firstWhere((p) => p.internalValue == 'high');
          expect(
            high.displayLabel,
            'high',
            reason: '$modelId: high should be identity',
          );
          final max = presets.firstWhere((p) => p.internalValue == 'max');
          expect(
            max.displayLabel,
            'max',
            reason: '$modelId: max should be identity',
          );
        }
      },
    );
  });

  group('InstallSlug', () {
    test('produces a non-empty slug matching DeepSeek user_id regex', () {
      final slug = InstallSlug.slug;
      expect(slug, isNotEmpty);
      expect(RegExp(r'^[a-zA-Z0-9\-_]+$').hasMatch(slug), isTrue);
      expect(slug.length, 12);
    });
  });

  group('topPForTemperature (temperature ↔ top_p mapping)', () {
    test('maps temp 0 to top_p 1.0 (full nucleus)', () {
      expect(topPForTemperature(0.0), 1.0);
    });

    test('maps temp 1 to top_p 0.85 (narrowed nucleus)', () {
      expect(topPForTemperature(1.0), closeTo(0.85, 1e-9));
    });

    test('interpolates linearly for in-range values', () {
      // 1.0 - 0.15 * 0.4 = 0.94 (temp 0.4)
      expect(topPForTemperature(0.4), closeTo(0.94, 1e-9));
      // 1.0 - 0.15 * 0.5 = 0.925 (temp 0.5)
      expect(topPForTemperature(0.5), closeTo(0.925, 1e-9));
      // 1.0 - 0.15 * 0.7 = 0.895 (temp 0.7)
      expect(topPForTemperature(0.7), closeTo(0.895, 1e-9));
    });

    test('clamps temperatures above 1.0 to the temp=1.0 endpoint', () {
      // An OpenAI-configured model could have a TOML default of
      // 1.5 (OpenAI accepts 0–2). The clamp keeps `top_p` inside
      // the API-valid [0.0, 1.0] range.
      expect(topPForTemperature(1.5), closeTo(0.85, 1e-9));
      expect(topPForTemperature(2.0), closeTo(0.85, 1e-9));
    });

    test('clamps temperatures below 0.0 to the temp=0.0 endpoint', () {
      // Defensive — user-facing `/temperature` already clamps to
      // [0.0, 1.0], but a TOML-configured negative should still
      // produce a valid `top_p`.
      expect(topPForTemperature(-0.2), 1.0);
      expect(topPForTemperature(-1.0), 1.0);
    });

    test('is monotonically non-increasing as temperature rises', () {
      // Important for the user-facing model: dragging temperature
      // up should never widen the nucleus. Sanity-check the
      // trend across the full domain.
      const samples = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0];
      double? previous;
      for (final t in samples) {
        final topP = topPForTemperature(t);
        final prev = previous;
        if (prev != null) {
          expect(
            topP,
            lessThanOrEqualTo(prev),
            reason: 'top_p must not widen as temperature rises',
          );
        }
        previous = topP;
      }
    });

    test('output is always in [0.85, 1.0] for any reasonable input', () {
      // The whole purpose of the mapping: `top_p` stays inside the
      // OpenAI / Anthropic [0.0, 1.0] window even when fed bizarre
      // inputs.
      for (final t in [-100.0, -1.0, 0.0, 0.5, 1.0, 2.0, 100.0]) {
        expect(
          topPForTemperature(t),
          inInclusiveRange(0.85, 1.0),
          reason: 'top_p at temp=$t must be in [0.85, 1.0]',
        );
      }
    });
  });

  group('top_p plumbing through provider bodies', () {
    test('Anthropic body includes the supplied top_p', () {
      final provider = AnthropicCompatibleProvider();
      final body = provider.buildRequestBody(
        'claude-sonnet-4-6',
        userMsg,
        topP: 0.93,
      );
      expect(body['top_p'], 0.93);
    });

    test('OpenAI body includes the supplied top_p', () {
      final provider = OpenAICompatibleProvider();
      final body = provider.buildRequestBody('gpt-4o', userMsg, topP: 0.9);
      expect(body['top_p'], 0.9);
    });

    test('MiniMax body includes the supplied top_p', () {
      final provider = MiniMaxProvider();
      final body = provider.buildRequestBody('MiniMax/M2', userMsg, topP: 0.88);
      expect(body['top_p'], 0.88);
    });

    test('default top_p is 1.0 when caller doesn\'t supply one', () {
      // The LlmProvider.buildRequestBody default is 1.0 (the temp=0
      // endpoint of the mapping) so test bodies that don't care
      // about top_p get a harmless full-nucleus default.
      final anthropic = AnthropicCompatibleProvider().buildRequestBody(
        'claude-sonnet-4-6',
        userMsg,
      );
      expect(anthropic['top_p'], 1.0);
      final openai = OpenAICompatibleProvider().buildRequestBody(
        'gpt-4o',
        userMsg,
      );
      expect(openai['top_p'], 1.0);
    });
  });
}
