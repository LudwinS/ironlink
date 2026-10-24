import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../data/direct_messages_repository.dart';
import '../../data/nodos_repository.dart';
import '../../data/reuniones_repository.dart';
import '../rtc_call_page.dart';

class DirectMessagesDialog extends StatefulWidget {
  const DirectMessagesDialog({
    super.key,
    required this.nodoId,
    required this.ownUserId,
    required this.members,
    this.initialPeerId,
  });

  final String nodoId;
  final String ownUserId;
  final List<NodoMiembro> members;
  final String? initialPeerId;

  @override
  State<DirectMessagesDialog> createState() => _DirectMessagesDialogState();
}

class _DirectMessagesDialogState extends State<DirectMessagesDialog> {
  final _repository = DirectMessagesRepository();
  final _composer = TextEditingController();
  Timer? _refreshTimer;
  List<DirectMessage> _inbox = [];
  List<DirectMessage> _messages = [];
  String? _peerId;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _peerId = widget.initialPeerId;
    unawaited(_refresh());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final inbox = await _repository.inbox(widget.nodoId);
      if (!mounted) return;
      setState(() {
        _inbox = inbox;
        _error = null;
      });
      final peer = _peerId;
      if (peer != null) {
        final messages = await _repository.history(widget.nodoId, peer);
        if (mounted && peer == _peerId) setState(() => _messages = messages);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudieron cargar los mensajes directos.');
      }
    }
  }

  Future<void> _select(String peerId) async {
    setState(() {
      _peerId = peerId;
      _messages = [];
    });
    await _refresh();
  }

  Future<void> _send() async {
    final peer = _peerId;
    final text = _composer.text.trim();
    if (peer == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _repository.sendText(widget.nodoId, peer, text);
      _composer.clear();
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo enviar el mensaje.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _join(DirectMessage invitation) async {
    try {
      final meetings = await ReunionesRepository().fetchReuniones(
        widget.nodoId,
      );
      final meeting = meetings
          .where((m) => m.id == invitation.reunionId && m.rtcEstado == 'active')
          .firstOrNull;
      if (meeting == null) {
        if (mounted) {
          setState(() => _error = 'Esta videollamada ya no está activa.');
        }
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RtcCallPage(
            reunion: meeting,
            canEnd: widget.ownUserId == meeting.creadoPor,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo entrar en la videollamada.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.members
        .where((m) => m.userId != widget.ownUserId)
        .toList();
    final selected = contacts.where((m) => m.userId == _peerId).firstOrNull;
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.all(8),
      child: SizedBox(
        width: min(830.0, MediaQuery.sizeOf(context).width - 16),
        height: min(
          580.0,
          MediaQuery.sizeOf(context).height -
              MediaQuery.viewInsetsOf(context).bottom -
              16,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            final showContacts = !narrow || _peerId == null;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Mensajes directos',
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _refresh,
                        icon: Icon(Icons.refresh, color: AppColors.textMuted),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      if (showContacts)
                        SizedBox(
                          width: narrow ? constraints.maxWidth : 250,
                          child: ListView(
                            children: contacts.map((member) {
                              final unread = _inbox
                                  .where(
                                    (m) =>
                                        m.senderId == member.userId &&
                                        m.readAt == null,
                                  )
                                  .length;
                              return ListTile(
                                selected: _peerId == member.userId,
                                selectedColor: AppColors.accent,
                                leading: Icon(
                                  Icons.person_outline,
                                  color: AppColors.textMuted,
                                ),
                                title: Text(
                                  member.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: AppColors.text),
                                ),
                                trailing: unread > 0
                                    ? CircleAvatar(
                                        radius: 12,
                                        backgroundColor: AppColors.accent,
                                        child: Text(
                                          '$unread',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      )
                                    : null,
                                onTap: () => _select(member.userId),
                              );
                            }).toList(),
                          ),
                        ),
                      if (!narrow || _peerId != null)
                        Expanded(
                          child: Column(
                            children: [
                              ListTile(
                                leading: narrow
                                    ? IconButton(
                                        icon: Icon(
                                          Icons.arrow_back,
                                          color: AppColors.text,
                                        ),
                                        onPressed: () =>
                                            setState(() => _peerId = null),
                                      )
                                    : null,
                                title: Text(
                                  selected?.name ?? 'Selecciona una persona',
                                  style: TextStyle(color: AppColors.text),
                                ),
                              ),
                              Divider(height: 1, color: AppColors.line),
                              Expanded(
                                child: _peerId == null
                                    ? Center(
                                        child: Text(
                                          'Elige un integrante para conversar.',
                                          style: TextStyle(
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(12),
                                        reverse: true,
                                        itemCount: _messages.length,
                                        itemBuilder: (context, index) {
                                          final message =
                                              _messages[_messages.length -
                                                  1 -
                                                  index];
                                          final mine =
                                              message.senderId ==
                                              widget.ownUserId;
                                          return Align(
                                            alignment: mine
                                                ? Alignment.centerRight
                                                : Alignment.centerLeft,
                                            child: Container(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              padding: const EdgeInsets.all(10),
                                              constraints: const BoxConstraints(
                                                maxWidth: 440,
                                              ),
                                              decoration: BoxDecoration(
                                                color: mine
                                                    ? AppColors.accentDeep
                                                    : AppColors.bg,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if (message.kind ==
                                                      'call_invite')
                                                    Icon(
                                                      Icons.video_call,
                                                      color: AppColors.accent,
                                                    ),
                                                  Text(
                                                    message.content,
                                                    style: TextStyle(
                                                      color: AppColors.text,
                                                    ),
                                                  ),
                                                  if (message.kind ==
                                                          'call_invite' &&
                                                      !mine &&
                                                      message.reunionId != null)
                                                    TextButton.icon(
                                                      onPressed: () =>
                                                          _join(message),
                                                      icon: const Icon(
                                                        Icons.call,
                                                      ),
                                                      label: const Text(
                                                        'Entrar a la llamada',
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                              if (_peerId != null)
                                Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _composer,
                                          maxLength: 2000,
                                          minLines: 1,
                                          maxLines: 3,
                                          style: TextStyle(
                                            color: AppColors.text,
                                          ),
                                          decoration: const InputDecoration(
                                            hintText:
                                                'Escribe un mensaje privado',
                                          ),
                                          onSubmitted: (_) => _send(),
                                        ),
                                      ),
                                      IconButton.filled(
                                        onPressed: _sending ? null : _send,
                                        icon: const Icon(Icons.send),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
