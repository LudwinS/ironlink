import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../data/rtc_participation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/security/secure_vault.dart';
import '../data/direct_messages_repository.dart';
import '../data/nodos_repository.dart';
import '../data/reuniones_repository.dart';
import '../data/breakout_repository.dart';
import '../data/rtc_call_controller.dart';
import 'widgets/breakout_dialog.dart';
import 'widgets/whiteboard_page.dart';
import '../data/whiteboard_controller.dart';
import 'widgets/rtc_presentation_layout.dart';
import 'widgets/rtc_audio_devices_dialog.dart';
import '../data/rtc_prejoin.dart';
import 'widgets/rtc_prejoin_view.dart';
import '../../../core/notify/iron_notice.dart';
import '../../../core/notify/iron_notify.dart';

/// Crea la conexión de una sala con el estado inicial de cámara y micrófono.
typedef RtcCallFactory =
    RtcCallController Function(
      BreakoutTarget target, {
      required bool microphoneEnabled,
      required bool cameraEnabled,
    });

/// Llamada de una reunión. Primero muestra la sala de espera (vista previa
/// de la cámara y elección de cámara/micrófono) y solo al pulsar «Unirse
/// ahora» se conecta a la sala.
class RtcCallPage extends StatefulWidget {
  const RtcCallPage({
    super.key,
    required this.reunion,
    required this.canEnd,
    @visibleForTesting this.media = const RtcMediaAccess(),
    @visibleForTesting this.callFactory,
    @visibleForTesting this.membersRepository,
  });
  final Reunion reunion;
  final bool canEnd;
  final RtcMediaAccess media;
  final RtcCallFactory? callFactory;
  final NodosRepository? membersRepository;

  @override
  State<RtcCallPage> createState() => _RtcCallPageState();
}

class _RtcCallPageState extends State<RtcCallPage> {
  /// Sala de espera; `null` una vez que se entra a la llamada.
  RtcPrejoin? _prejoin;
  RtcCallController? _call;
  RtcCallController get call => _call!;

  // IRL-RTC-US-07: canal actual y cambio de sala pendiente.
  BreakoutTarget _channel = BreakoutTarget.main;
  BreakoutTarget? _offer;
  bool _offerDismissed = false;
  bool _moving = false;
  Timer? _autoMove;
  int _seconds = 0;
  bool _whiteboardOpen = false;
  late final _membersRepository = widget.membersRepository ?? NodosRepository();
  final _messagesRepository = DirectMessagesRepository();
  List<NodoMiembro> _members = [];
  String? _myName;
  bool _selectingScreen = false;
  String? _presenterId;

  Future<void> _moderationAction(
    String action, {
    String? target,
    bool? allowed,
  }) async {
    if (action == 'kick' || action == 'mute_all') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == 'kick'
                ? '¿Expulsar de esta reunión?'
                : '¿Silenciar a los participantes?',
          ),
          content: Text(
            action == 'kick'
                ? 'No podrá volver a entrar a esta reunión. Su membresía del nodo no cambia.'
                : 'Los participantes deberán recibir permiso para activar su micrófono de nuevo. No afecta a otros moderadores.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await call.moderate(action, target: target, allowed: allowed);
  }

  Future<void> _showModeration() => showDialog<void>(
    context: context,
    builder: (_) => AnimatedBuilder(
      animation: call,
      builder: (context, _) => AlertDialog(
        title: const Text('Moderación de la reunión'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Permitir audio o video no los activa automáticamente. Los otros moderadores están protegidos.',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: call.canModerate && !call.moderationBusy
                      ? () => _moderationAction('mute_all')
                      : null,
                  icon: const Icon(Icons.mic_off),
                  label: const Text('Silenciar a todos'),
                ),
                for (final peer in call.peers)
                  ListTile(
                    title: Text(
                      _nameFor(peer.userId),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Controles del participante',
                      enabled: call.canModerate && !call.moderationBusy,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'microphone_block',
                          child: Text('Silenciar y bloquear micrófono'),
                        ),
                        PopupMenuItem(
                          value: 'microphone_allow',
                          child: Text('Permitir micrófono'),
                        ),
                        PopupMenuItem(
                          value: 'camera_block',
                          child: Text('Bloquear cámara y pantalla'),
                        ),
                        PopupMenuItem(
                          value: 'camera_allow',
                          child: Text('Permitir cámara y pantalla'),
                        ),
                        PopupMenuItem(
                          value: 'kick',
                          child: Text('Expulsar de la reunión'),
                        ),
                      ],
                      onSelected: (action) {
                        if (action == 'kick') {
                          unawaited(
                            _moderationAction('kick', target: peer.userId),
                          );
                        } else {
                          unawaited(
                            _moderationAction(
                              action.startsWith('microphone')
                                  ? 'microphone'
                                  : 'camera',
                              target: peer.userId,
                              allowed: action.endsWith('allow'),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                if (call.peers.isEmpty)
                  const Text('No hay otros participantes conectados.'),
                if (call.moderationBusy) const LinearProgressIndicator(),
                if (call.moderationError != null)
                  Text(
                    call.moderationError!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    ),
  );

  Future<void> _shareScreen() async {
    if (_selectingScreen || call.screenBusy) return;
    if (call.screenSharing) {
      await call.stopScreenShare();
      return;
    }
    if (!call.canShareScreen) return;
    if (kIsWeb) {
      await call.startScreenShare();
      return;
    }
    setState(() => _selectingScreen = true);
    try {
      final sources = await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window],
      );
      if (!mounted || !call.canShareScreen) return;
      final sourceId = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('¿Qué quieres compartir?'),
          content: SizedBox(
            width: 440,
            height: MediaQuery.sizeOf(dialogContext).height * 0.5,
            child: sources.isEmpty
                ? const Text(
                    'No hay pantallas o ventanas disponibles. Revisa el permiso de grabación de pantalla.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Los demás verán todo el contenido de la fuente elegida. No se comparte el audio del sistema.',
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final source in sources)
                              ListTile(
                                leading: Icon(
                                  source.type == SourceType.Screen
                                      ? Icons.desktop_windows
                                      : Icons.web_asset,
                                ),
                                title: Text(
                                  source.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  source.type == SourceType.Screen
                                      ? 'Pantalla completa'
                                      : 'Solo esta ventana',
                                ),
                                onTap: () =>
                                    Navigator.pop(dialogContext, source.id),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      );
      if (sourceId != null && mounted) {
        await call.startScreenShare(sourceId: sourceId);
      }
    } catch (_) {
      if (mounted) {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.error,
            title:
                'No se pudieron listar las pantallas. Revisa los permisos de IronLink.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingScreen = false);
    }
  }

  RtcCallController _create(
    BreakoutTarget target, {
    required bool microphoneEnabled,
    required bool cameraEnabled,
  }) =>
      (widget.callFactory?.call(
              target,
              microphoneEnabled: microphoneEnabled,
              cameraEnabled: cameraEnabled,
            ) ??
            RtcCallController(
              widget.reunion.nodoId,
              widget.reunion.id,
              ReunionesRepository(),
              salaId: target.id,
              microphoneEnabled: microphoneEnabled,
              cameraEnabled: cameraEnabled,
            ))
        ..addListener(_onCallChanged);

  /// «Unirse ahora»: la llamada recibe el stream de la vista previa (no se
  /// vuelve a abrir la cámara) y el estado elegido de cámara y micrófono.
  void _joinFromLobby() {
    final prejoin = _prejoin;
    if (prejoin == null || _call != null) return;
    final camera = prejoin.cameraEnabled;
    final microphone = prejoin.microphoneEnabled;
    final inputId = prejoin.audioDevices.inputId;
    final outputId = prejoin.audioDevices.outputId;
    final media = prejoin.takeStream();
    final created = _create(
      BreakoutTarget.main,
      microphoneEnabled: microphone,
      cameraEnabled: camera,
    );
    created.audioDevices
      ..inputId = inputId
      ..outputId = outputId;
    setState(() {
      _prejoin = null;
      _call = created;
    });
    // La vista del lobby suelta su renderizador al desmontarse.
    WidgetsBinding.instance.addPostFrameCallback((_) => prejoin.dispose());
    unawaited(created.join(media: media));
  }

  /// El moderador asignó otra sala o cerró las salas: se anuncia y, si no se
  /// elige otra cosa, se cambia sola (10 s a una sala, 3 s de vuelta).
  void _onCallChanged() {
    final pending = call.pendingBreakout;
    if (pending == null || pending == _offer || _moving) return;
    _offer = pending;
    _offerDismissed = false;
    _autoMove?.cancel();
    setState(() => _seconds = pending.isMain ? 3 : 10);
    _autoMove = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _offer == null) return timer.cancel();
      if (_seconds <= 1) {
        timer.cancel();
        unawaited(_moveTo(_offer!));
      } else {
        setState(() => _seconds--);
      }
    });
  }

  /// Cambia de canal: cierra la conexión actual y entra a la sala destino.
  Future<void> _moveTo(BreakoutTarget target) async {
    if (_moving) return;
    _moving = true;
    _autoMove?.cancel();
    // La pizarra abierta es la del canal que se deja.
    if (_whiteboardOpen && mounted) Navigator.of(context).pop();
    final old = call;
    old.removeListener(_onCallChanged);
    await old.close();
    old.dispose();
    if (!mounted) return;
    setState(() {
      _channel = target;
      _offer = null;
      _presenterId = null;
      _call = _create(
        target,
        microphoneEnabled: old.microphoneEnabled,
        cameraEnabled: old.cameraEnabled,
      );
    });
    _moving = false;
    unawaited(call.join());
  }

  /// IRL-RTC-US-08: pizarra del canal actual.
  Future<void> _openWhiteboard() async {
    final board = WhiteboardController(
      nodeId: widget.reunion.nodoId,
      reunionId: widget.reunion.id,
      salaId: _channel.id,
      ownUserId: call.ownUserId,
      events: call.whiteboardEvents,
    );
    final current = call;
    current.markWhiteboardSeen();
    _whiteboardOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WhiteboardPage(
          controller: board,
          title: _channel.isMain ? 'Pizarra' : 'Pizarra · ${_channel.name}',
        ),
      ),
    );
    _whiteboardOpen = false;
    board.dispose();
    if (identical(current, call)) current.markWhiteboardSeen();
  }

  Future<void> _openBreakouts() async {
    final target = await showBreakoutDialog(
      context,
      nodoId: widget.reunion.nodoId,
      reunionId: widget.reunion.id,
      ownUserId: call.ownUserId,
    );
    if (target != null && target != _channel && mounted) {
      await _moveTo(target);
    }
  }

  Widget _breakoutBanner(BreakoutTarget offer) => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.accentTint,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.accentDeep),
    ),
    child: Semantics(
      liveRegion: true,
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            offer.isMain
                ? 'Las salas se cerraron. Volverás a la sala principal en $_seconds s.'
                : 'Te asignaron a «${offer.name}». Entrarás en $_seconds s.',
            style: TextStyle(color: AppColors.text),
          ),
          OutlinedButton(
            onPressed: () => _moveTo(offer),
            child: const Text('Ir ahora'),
          ),
          if (!offer.isMain)
            TextButton(
              onPressed: () {
                _autoMove?.cancel();
                setState(() => _offerDismissed = true);
              },
              child: const Text('Ahora no'),
            ),
        ],
      ),
    ),
  );

  @override
  void initState() {
    super.initState();
    final prejoin = RtcPrejoin(media: widget.media);
    _prejoin = prejoin;
    unawaited(prejoin.start());
    unawaited(_loadMembers());
  }

  Future<void> _loadMembers() async {
    try {
      final members = await _membersRepository.fetchMiembros(
        widget.reunion.nodoId,
      );
      final name = await SecureVault.getUsername();
      if (mounted) {
        setState(() {
          _members = members;
          _myName = name;
        });
      }
    } catch (_) {
      // La llamada permanece utilizable aunque la lista de miembros falle.
    }
  }

  String _nameFor(String userId) {
    for (final member in _members) {
      if (member.userId == userId) return member.name;
    }
    return 'Participante';
  }

  Future<void> _showInviteDialog() async {
    await _loadMembers();
    if (!mounted) return;
    final candidates = _members
        .where(
          (member) =>
              member.userId != call.ownUserId &&
              !call.peers.any((peer) => peer.userId == member.userId),
        )
        .toList();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Añadir a la videollamada'),
        content: SizedBox(
          width: 400,
          child: candidates.isEmpty
              ? const Text('No hay otros miembros disponibles en este nodo.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (context, index) {
                    final member = candidates[index];
                    return ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(member.name),
                      subtitle: Text(member.email),
                      trailing: const Icon(Icons.send_outlined),
                      onTap: () async {
                        try {
                          await _messagesRepository.invite(
                            widget.reunion.nodoId,
                            member.userId,
                            widget.reunion.id,
                          );
                          if (!mounted || !dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop();
                          IronNotify.show(
                            IronNotice(
                              kind: NoticeKind.success,
                              title:
                                  'Invitación enviada a ${member.name} por chat directo.',
                            ),
                          );
                        } catch (_) {
                          if (!dialogContext.mounted) return;
                          IronNotify.show(
                            IronNotice(
                              kind: NoticeKind.error,
                              title: 'No se pudo enviar la invitación.',
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoMove?.cancel();
    final prejoin = _prejoin;
    if (prejoin != null) {
      unawaited(prejoin.close().whenComplete(prejoin.dispose));
    }
    final current = _call;
    if (current != null) {
      current.removeListener(_onCallChanged);
      unawaited(current.close().whenComplete(current.dispose));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prejoin = _prejoin;
    if (prejoin != null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          title: const Text('Antes de entrar'),
        ),
        body: SafeArea(
          child: RtcPrejoinView(
            prejoin: prejoin,
            title: widget.reunion.titulo,
            userName: _myName,
            onJoin: _joinFromLobby,
            onCancel: () => Navigator.of(context).pop(),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: call,
      builder: (context, _) => Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          foregroundColor: Colors.white,
          title: Text(
            _channel.isMain
                ? widget.reunion.titulo
                : '${widget.reunion.titulo} · ${_channel.name}',
          ),
        ),
        body: Column(
          children: [
            if (call.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  call.error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            if (call.screenError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  call.screenError!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                call.status,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            if (_offer != null && !_offerDismissed) _breakoutBanner(_offer!),
            if (!_channel.isMain || (_offer != null && _offerDismissed))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(Icons.call_split_rounded, color: AppColors.accentText),
                    if (!_channel.isMain)
                      Text(
                        'Estás en «${_channel.name}»',
                        style: TextStyle(color: AppColors.text),
                      ),
                    if (_offer != null && _offerDismissed)
                      TextButton(
                        onPressed: () => _moveTo(_offer!),
                        child: Text('Ir a «${_offer!.name}»'),
                      )
                    else if (!_channel.isMain)
                      TextButton(
                        onPressed: () => _moveTo(BreakoutTarget.main),
                        child: const Text('Volver a la sala principal'),
                      ),
                  ],
                ),
              ),
            if (!call.permissions.microphoneAllowed ||
                !call.permissions.cameraAllowed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'El moderador ha bloqueado ${!call.permissions.microphoneAllowed ? 'el micrófono' : ''}${!call.permissions.microphoneAllowed && !call.permissions.cameraAllowed ? ' y ' : ''}${!call.permissions.cameraAllowed ? 'la cámara y la pantalla' : ''}.',
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (_raisedHands().isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    'Turnos solicitados: ${_raisedHands().join(' → ')}',
                    style: TextStyle(color: AppColors.accent),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            if (call.ownUserId != null &&
                call.error == null &&
                !call.canInteract)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Actualiza el backend para habilitar mano levantada y reacciones.',
                  style: TextStyle(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final remote = call.peers;
                  if (call.screenSharing ||
                      remote.any((peer) => peer.participation.screenSharing)) {
                    return _presentation();
                  }
                  final canInvite = remote.length < 2;
                  final tiles = 1 + remote.length + (canInvite ? 1 : 0);
                  final columns = constraints.maxWidth >= 700 ? 2 : 1;
                  return GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      childAspectRatio: columns == 2 ? 1.45 : 1.65,
                    ),
                    itemCount: tiles,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _video(
                          call.localRenderer,
                          call.renderersReady && call.cameraEnabled,
                          '${_nameFor(call.ownUserId ?? '') == 'Participante' ? (_myName ?? 'Tú') : _nameFor(call.ownUserId!)} (Tú)',
                          mirror: true,
                          muted: !call.microphoneEnabled,
                          speaking: call.localSpeaking,
                          handRaised: call.participation.handRaised,
                          reaction: call.participation.visibleReaction(
                            DateTime.now(),
                          ),
                        );
                      }
                      if (canInvite && index == tiles - 1) {
                        return InkWell(
                          onTap: _showInviteDialog,
                          child: Container(
                            margin: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: AppColors.accent,
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.person_add_alt_1,
                                  color: AppColors.accent,
                                  size: 54,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Añadir usuario',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      final peer = remote[index - 1];
                      return _video(
                        peer.renderer,
                        peer.visible,
                        _nameFor(peer.userId),
                        speaking: peer.speaking,
                        muted: !peer.participation.microphoneEnabled,
                        handRaised: peer.participation.handRaised,
                        reaction: peer.participation.visibleReaction(
                          DateTime.now(),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 12,
                children: [
                  IconButton.filledTonal(
                    tooltip: call.microphoneEnabled
                        ? 'Silenciar micrófono'
                        : 'Activar micrófono',
                    onPressed:
                        call.permissions.microphoneAllowed &&
                            (call.hasMicrophone || call.microphoneEnabled)
                        ? call.toggleMicrophone
                        : null,
                    icon: Icon(
                      call.microphoneEnabled ? Icons.mic : Icons.mic_off,
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Elegir micrófono y salida de audio',
                    onPressed: call.canSelectAudioDevices
                        ? () async {
                            unawaited(call.audioDevices.refresh());
                            await showDialog<void>(
                              context: context,
                              builder: (_) => RtcAudioDevicesDialog(
                                devices: call.audioDevices,
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.tune),
                  ),
                  IconButton.filledTonal(
                    tooltip: call.cameraEnabled
                        ? 'Apagar cámara'
                        : 'Activar cámara',
                    onPressed:
                        call.permissions.cameraAllowed &&
                            (call.hasCamera || call.cameraEnabled)
                        ? call.toggleCamera
                        : null,
                    icon: Icon(
                      call.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: call.screenSharing
                        ? 'Dejar de compartir pantalla'
                        : 'Compartir pantalla o ventana',
                    isSelected: call.screenSharing,
                    onPressed:
                        call.canShareScreen &&
                            !call.screenBusy &&
                            !_selectingScreen
                        ? _shareScreen
                        : null,
                    icon: Icon(
                      call.screenSharing
                          ? Icons.stop_screen_share
                          : Icons.screen_share_outlined,
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: call.participation.handRaised
                        ? 'Bajar la mano'
                        : 'Levantar la mano',
                    isSelected: call.participation.handRaised,
                    onPressed: call.canInteract ? call.toggleHand : null,
                    icon: const Icon(Icons.front_hand_outlined),
                    selectedIcon: Icon(
                      Icons.front_hand,
                      color: AppColors.accent,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Enviar reacción',
                    enabled: call.canInteract,
                    icon: const Icon(Icons.add_reaction_outlined),
                    onSelected: call.sendReaction,
                    itemBuilder: (_) => [
                      for (final emoji in RtcParticipation.reactions)
                        PopupMenuItem(
                          value: emoji,
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                    ],
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.call_end),
                    label: const Text('Salir'),
                  ),
                  if (call.canModerate)
                    IconButton.filledTonal(
                      tooltip: 'Moderar participantes',
                      onPressed: _showModeration,
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                    ),
                  IconButton.filledTonal(
                    tooltip: call.whiteboardActivity > 0
                        ? 'Pizarra, hay trazos nuevos'
                        : 'Pizarra',
                    onPressed: _openWhiteboard,
                    icon: Badge(
                      isLabelVisible: call.whiteboardActivity > 0,
                      smallSize: 8,
                      child: const Icon(Icons.draw_outlined),
                    ),
                  ),
                  if (call.canModerate)
                    IconButton.filledTonal(
                      tooltip: 'Salas de trabajo',
                      onPressed: _openBreakouts,
                      icon: const Icon(Icons.call_split_rounded),
                    ),
                  if (widget.canEnd)
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          await call.repository.endMeeting(
                            nodoId: widget.reunion.nodoId,
                            reunionId: widget.reunion.id,
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        } catch (_) {
                          if (context.mounted) {
                            IronNotify.show(
                              IronNotice(
                                kind: NoticeKind.error,
                                title: 'No se pudo finalizar la reunión.',
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Finalizar para todos'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _raisedHands() {
    final hands = <MapEntry<String, DateTime>>[
      if (call.participation.handRaisedAt != null)
        MapEntry('Tú', call.participation.handRaisedAt!),
      for (final peer in call.peers)
        if (peer.participation.handRaisedAt != null)
          MapEntry(_nameFor(peer.userId), peer.participation.handRaisedAt!),
    ]..sort((a, b) => a.value.compareTo(b.value));
    return hands.map((h) => h.key).toList();
  }

  Widget _localTile({bool avatarOnly = false}) => _video(
    call.localRenderer,
    !avatarOnly &&
        call.renderersReady &&
        (call.cameraEnabled || call.screenSharing),
    '${_myName ?? _nameFor(call.ownUserId ?? '')} (Tú)',
    mirror: !call.screenSharing,
    muted: !call.microphoneEnabled,
    speaking: call.localSpeaking,
    handRaised: call.participation.handRaised,
    reaction: call.participation.visibleReaction(DateTime.now()),
  );

  Widget _peerTile(RtcRemotePeer peer, {bool avatarOnly = false}) => _video(
    peer.renderer,
    !avatarOnly && peer.visible,
    _nameFor(peer.userId),
    muted: !peer.participation.microphoneEnabled,
    speaking: peer.speaking,
    handRaised: peer.participation.handRaised,
    reaction: peer.participation.visibleReaction(DateTime.now()),
  );

  Widget _presentation() {
    final presenters = <String>[
      if (call.screenSharing) '@local',
      for (final peer in call.peers)
        if (peer.participation.screenSharing) peer.userId,
    ];
    final selected = presenters.contains(_presenterId)
        ? _presenterId!
        : presenters.first;
    final selectedPeer = call.peers
        .where((peer) => peer.userId == selected)
        .firstOrNull;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(Icons.screen_share, color: Colors.white70, size: 18),
              for (final id in presenters)
                ChoiceChip(
                  label: Text(
                    id == '@local'
                        ? 'Tu pantalla'
                        : 'Pantalla de ${_nameFor(id)}',
                  ),
                  selected: selected == id,
                  onSelected: (_) => setState(() => _presenterId = id),
                ),
            ],
          ),
        ),
        Expanded(
          child: RtcPresentationLayout(
            presentation: selected == '@local'
                ? _localTile()
                : _peerTile(selectedPeer!),
            participants: [
              _localTile(avatarOnly: selected == '@local'),
              for (final peer in call.peers)
                _peerTile(peer, avatarOnly: selected == peer.userId),
            ],
          ),
        ),
      ],
    );
  }

  Widget _video(
    RTCVideoRenderer renderer,
    bool ready,
    String label, {
    bool mirror = false,
    bool speaking = false,
    bool muted = false,
    bool handRaised = false,
    String? reaction,
  }) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: speaking ? AppColors.accent : AppColors.line,
          width: speaking ? 4 : 1,
        ),
        boxShadow: speaking
            ? [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.5),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            RTCVideoView(
              renderer,
              mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            )
          else
            const Center(
              child: Icon(Icons.person, color: Colors.white54, size: 72),
            ),
          if (handRaised)
            Positioned(
              left: 12,
              top: 12,
              child: Tooltip(
                message: 'Mano levantada',
                child: Icon(
                  Icons.front_hand,
                  color: AppColors.accent,
                  size: 28,
                ),
              ),
            ),
          if (reaction != null)
            Center(
              child: Semantics(
                label: 'Reacción $reaction',
                liveRegion: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(reaction, style: const TextStyle(fontSize: 52)),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (speaking)
                      Icon(Icons.graphic_eq, color: AppColors.accent, size: 17),
                    if (muted)
                      const Icon(
                        Icons.mic_off,
                        color: Colors.redAccent,
                        size: 17,
                      ),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
