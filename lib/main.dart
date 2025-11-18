// Full Flutter app for speech → backend → calendar flow

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const EventAssistantApp());
}

class EventAssistantApp extends StatelessWidget {
  const EventAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Speech Calendar',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const EventHomePage(),
    );
  }
}

class EventHomePage extends StatefulWidget {
  const EventHomePage({super.key});

  @override
  State<EventHomePage> createState() => _EventHomePageState();
}

class _EventHomePageState extends State<EventHomePage> with TickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isListening = false;
  String _transcript = '';
  String _assistantText = '';

  // extracted fields from backend
  String _title = '';
  DateTime? _start;
  DateTime? _end;
  String _location = '';

  // replace with your Render backend base URL
  final String backendBase = 'https://calendar-ai-m1u7.onrender.com';

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setSharedInstance(true);
    await _tts.setLanguage('en-US');
  }

  Future<void> _ensureMicPermission() async {
    final status = await Permission.microphone.status;
    if (!status.isGranted) {
      await Permission.microphone.request();
    }
  }

  Future<void> _startListening() async {
    await _ensureMicPermission();
    final available = await _speech.initialize(
      onStatus: (s) {},
      onError: (e) {},
    );
    if (!available) {
      setState(() => _assistantText = 'Speech not available');
      return;
    }
    setState(() {
      _isListening = true;
      _transcript = '';
    });
    _speech.listen(
      onResult: (result) {
        setState(() => _transcript = result.recognizedWords);
      },
      listenFor: const Duration(seconds: 12),
      pauseFor: const Duration(seconds: 2),
      localeId: 'en_US',
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _isListening = false);
    if (_transcript.isNotEmpty) {
      await _sendExtract(_transcript);
    }
  }

  Future<void> _sendExtract(String text) async {
    final url = Uri.parse('$backendBase/extract');
    setState(() {
      _assistantText = 'Processing...';
    });

    try {
      final res = await http.post(url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'text': text}));

      final data = json.decode(res.body);

      // populate fields if present
      setState(() {
        _title = data['title'] ?? '';
        _location = data['location'] ?? '';
        _assistantText = data['spoken_response'] ?? '';

        // parse start/end if provided
        try {
          _start = data['start'] != null && (data['start'] as String).isNotEmpty
              ? DateTime.parse(data['start'])
              : null;
        } catch (_) {
          _start = null;
        }
        try {
          _end = data['end'] != null && (data['end'] as String).isNotEmpty
              ? DateTime.parse(data['end'])
              : null;
        } catch (_) {
          _end = null;
        }
      });

      await _tts.speak(_assistantText);
    } catch (e) {
      setState(() => _assistantText = 'Network error: $e');
      await _tts.speak('There was a connection error');
    }
  }

  Future<void> _callCheckConflicts() async {
    if (_start == null || _end == null) {
      await _tts.speak('Please set start and end times before checking for conflicts.');
      return;
    }
    final url = Uri.parse('$backendBase/check_conflicts');
    setState(() => _assistantText = 'Checking conflicts...');

    try {
      final res = await http.post(url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'start': _start!.toIso8601String(),
            'end': _end!.toIso8601String()
          }));

      final data = json.decode(res.body);
      setState(() => _assistantText = data['spoken_response'] ?? '');

      await _tts.speak(_assistantText);

      final conflicts = (data['conflicts'] as List<dynamic>?) ?? [];
      if (conflicts.isNotEmpty) {
        // show conflict dialog
        final items = conflicts.map((c) {
          final title = c['title'] ?? 'Untitled';
          final start = c['start'] ?? '';
          final end = c['end'] ?? '';
          return '$title — $start to $end';
        }).join('/n');

        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Conflicts found'),
            content: SingleChildScrollView(child: Text(items)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, 'reschedule'),
                  child: const Text('Reschedule')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, 'force'),
                  child: const Text('Add Anyway')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: const Text('Cancel')),
            ],
          ),
        );

        if (choice == 'reschedule') {
          await _pickStartEnd();
        } else if (choice == 'force') {
          await _callAddEvent(force: true);
        }
      } else {
        // no conflicts — proceed to add
        await _callAddEvent();
      }
    } catch (e) {
      setState(() => _assistantText = 'Error checking conflicts: $e');
      await _tts.speak('There was an error checking conflicts');
    }
  }

  Future<void> _callAddEvent({bool force = false}) async {
    if (_title.isEmpty || _start == null || _end == null) {
      await _tts.speak('Please ensure title, start and end are set before adding the event.');
      return;
    }

    final url = Uri.parse('$backendBase/add_event');
    setState(() => _assistantText = 'Adding event...');

    try {
      final res = await http.post(url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'title': _title,
            'start': _start!.toIso8601String(),
            'end': _end!.toIso8601String(),
            'location': _location,
            // optional: let backend know if we forced it
            'force': force
          }));

      final data = json.decode(res.body);
      setState(() => _assistantText = data['spoken_response'] ?? '');
      await _tts.speak(_assistantText);
    } catch (e) {
      setState(() => _assistantText = 'Error adding event: $e');
      await _tts.speak('Could not add the event.');
    }
  }

  Future<void> _pickStartEnd() async {
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _start ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start ?? now.add(const Duration(hours: 1))),
    );
    if (pickedTime == null) return;

    final newStart = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime.hour, pickedTime.minute);

    // pick end
    final pickedDate2 = await showDatePicker(
      context: context,
      initialDate: _end ?? newStart.add(const Duration(hours: 1)),
      firstDate: pickedDate,
      lastDate: DateTime(now.year + 3),
    );
    if (pickedDate2 == null) return;

    final pickedTime2 = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_end ?? newStart.add(const Duration(hours: 1))),
    );
    if (pickedTime2 == null) return;

    final newEnd = DateTime(pickedDate2.year, pickedDate2.month, pickedDate2.day, pickedTime2.hour, pickedTime2.minute);

    setState(() {
      _start = newStart;
      _end = newEnd;
    });

    // After rescheduling, re-run conflict check
    await _callCheckAfterPick();
  }

  Future<void> _callCheckAfterPick() async {
    // speak and check conflicts
    await _tts.speak('Checking conflicts for the new time');
    await _callCheckConflicts();
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return 'Not set';
    return '${dt.month}/${dt.day}/${dt.year} ${dt.hour % 12 == 0 ? 12 : dt.hour % 12}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Event Assistant'),
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Transcript card
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('You said', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_transcript.isEmpty ? 'Tap the mic and speak' : _transcript),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Assistant response
              Card(
                color: Colors.grey[50],
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Assistant', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_assistantText.isEmpty ? '—' : _assistantText),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Extracted fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Extracted Event (editable)', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(labelText: 'Title'),
                        controller: TextEditingController.fromValue(TextEditingValue(text: _title)),
                        onChanged: (v) => _title = v,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: Text('Start: ${_formatDateTime(_start)}')),
                          TextButton(onPressed: _pickStartEnd, child: const Text('Pick')),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(child: Text('End:   ${_formatDateTime(_end)}')),
                          // pickStartEnd will pick both start & end; keep UI simple
                          const SizedBox(width: 8),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(labelText: 'Location (optional)'),
                        controller: TextEditingController.fromValue(TextEditingValue(text: _location)),
                        onChanged: (v) => _location = v,
                      ),
                      const SizedBox(height: 12),

                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _callCheckConflicts,
                              child: const Text('Check Conflicts & Add'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            onPressed: () async {
                              // replay assistant text
                              if (_assistantText.isNotEmpty) await _tts.speak(_assistantText);
                            },
                            icon: const Icon(Icons.volume_up),
                          )
                        ],
                      ),
                      const SizedBox(height: 20),

                      const Text('Quick controls', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          FloatingActionButton.extended(
                            heroTag: 'mic',
                            onPressed: _isListening ? _stopListening : _startListening,
                            label: Text(_isListening ? 'Stop' : 'Speak'),
                            icon: Icon(_isListening ? Icons.stop : Icons.mic),
                          ),
                          FloatingActionButton.extended(
                            heroTag: 'reschedule',
                            onPressed: _pickStartEnd,
                            label: const Text('Reschedule'),
                            icon: const Icon(Icons.schedule),
                          ),
                          FloatingActionButton.extended(
                            heroTag: 'addnow',
                            onPressed: () => _callAddEvent(),
                            label: const Text('Add Now'),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
