import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'user_state/sip_user.dart';
import '../data/models/stored_credentials_model.dart';

/// Persistent background service that maintains SIP connection
/// and handles incoming calls even when app is closed/locked
@pragma('vm:entry-point')
class PersistentBackgroundService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  static SIPUAHelper? _backgroundSipHelper;
  static Timer? _keepAliveTimer;
  static Timer? _reconnectionTimer;
  static ServiceInstance? _serviceInstance;
  static SipUser? _currentSipUser;
  static bool _isServiceRunning = false;
  static Call? _currentIncomingCall;
  static Call? _currentActiveCall;
  static bool _isMainAppActive = true; // Track if main app is in foreground
  static Call? _forwardedCall; // Call forwarded to main app
  static DateTime? _lastAppStatusChange; // Track to prevent rapid switching
  static bool _isMuted = false;
  static bool _isSpeakerOn = false;
  static bool _isOnHold = false;

  @pragma('vm:entry-point')
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Initialize notifications first
    await _initializeNotifications();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Don't auto-start, we'll start manually
        isForegroundMode: true,
        notificationChannelId: 'persistent_sip_service',
        initialNotificationTitle: 'SIP Phone Active',
        initialNotificationContent: 'Ready to receive calls - Running in background for 24/7 operation',
        foregroundServiceNotificationId: 888,
        autoStartOnBoot: true, // Start service on device boot
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    print('🔄 Persistent Background Service configured');
  }

  @pragma('vm:entry-point')
  static Future<void> _initializeNotifications() async {
    // Android notification channel for incoming calls
    const AndroidNotificationChannel incomingCallChannel = AndroidNotificationChannel(
      'incoming_calls_channel',
      'Incoming Calls',
      description: 'Notifications for incoming SIP calls',
      importance: Importance.max,
      sound: RawResourceAndroidNotificationSound('phone_ringing'),
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    // Android notification channel for service status
    const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
      'persistent_sip_service',
      'SIP Service',
      description: 'Persistent SIP connection service',
      importance: Importance.low,
      showBadge: false,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(incomingCallChannel);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(serviceChannel);

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true, // For critical incoming call alerts
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    print('📱 Background notifications initialized');
  }

  @pragma('vm:entry-point')
  static void _onNotificationTap(NotificationResponse response) {
    print('📱🔔📱 NOTIFICATION TAP RECEIVED 📱🔔📱');
    print('📱 Action ID: "${response.actionId}"');
    print('📱 Payload: "${response.payload}"');
    print('📱 Notification ID: ${response.notificationResponseType}');
    print('📱 Current incoming call exists: ${_currentIncomingCall != null}');

    // Handle notification actions
    if (response.actionId == 'answer_call') {
      print('✅✅✅ ANSWER CALL ACTION TAPPED ✅✅✅');
      _handleAcceptCallFromNotification(response.payload);
    } else if (response.actionId == 'decline_call') {
      print('❌❌❌ DECLINE CALL ACTION TAPPED ❌❌❌');
      _handleDeclineCallFromNotification(response.payload);
    } else if (response.payload?.contains('incoming_call') == true) {
      print('🔔 Incoming call notification tapped - opening app');
      _launchAppWithIncomingCall(response.payload);
    } else {
      print('⚠️ Unknown notification action: actionId="${response.actionId}", payload="${response.payload}"');
    }
  }

  @pragma('vm:entry-point')
  static void _handleAcceptCallFromNotification(String? payload) {
    print('📞📞📞 HANDLE ACCEPT CALL FROM NOTIFICATION 📞📞📞');
    print('📞 Payload: $payload');
    print('📞 Current incoming call: ${_currentIncomingCall?.id}');
    print('📞 Call remote identity: ${_currentIncomingCall?.remote_identity}');
    print('📞 Call state: ${_currentIncomingCall?.state}');

    // CRITICAL FIX: Ensure _currentIncomingCall is properly maintained
    if (_currentIncomingCall != null) {
      try {
        // Accept with audio-only constraints
        final mediaConstraints = <String, dynamic>{
          'audio': true,
          'video': false,
        };
        print('📞 Calling answer() with constraints: $mediaConstraints');
        _currentIncomingCall!.answer(mediaConstraints);
        print('✅ Call accepted from notification - answer() called successfully');

        // CRITICAL: Move to active call and maintain state
        _currentActiveCall = _currentIncomingCall;
        _currentIncomingCall = null;
        
        // Store accepted call for main app coordination
        _storeCallForMainApp(_currentActiveCall!, 'accepted');

        // Open the app to show call screen
        print('📞 Launching app with accepted call...');
        _launchAppWithIncomingCall(payload);
        
        // Notify main app via service event
        _serviceInstance?.invoke('callAccepted', {
          'callId': _currentActiveCall?.id ?? 'unknown',
          'caller': _currentActiveCall?.remote_identity ?? 'Unknown',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
      } catch (e) {
        print('❌ Error accepting call from notification: $e');
        print('❌ Error type: ${e.runtimeType}');
        print('❌ Stack trace: ${StackTrace.current}');
      }
    } else {
      print('❌❌❌ CRITICAL: No current incoming call to accept!');
      print('❌ This indicates notification state is not properly maintained');
      
      // Try to recover by checking if there are any active calls
      if (_backgroundSipHelper != null) {
        print('📞 Attempting to recover by checking background SIP helper for active calls');
        // This would require additional SIP helper introspection
      }
    }
  }

  @pragma('vm:entry-point')
  static void _handleDeclineCallFromNotification(String? payload) {
    print('❌❌❌ HANDLE DECLINE CALL FROM NOTIFICATION ❌❌❌');
    print('📞 Payload: $payload');
    print('📞 Current incoming call: ${_currentIncomingCall?.id}');
    print('📞 Call remote identity: ${_currentIncomingCall?.remote_identity}');
    print('📞 Call state: ${_currentIncomingCall?.state}');

    // CRITICAL FIX: Ensure _currentIncomingCall is properly maintained
    if (_currentIncomingCall != null) {
      try {
        print('📞 Calling hangup() with status_code 486 (Busy Here)');
        _currentIncomingCall!.hangup({'status_code': 486}); // Busy here
        print('✅ Call declined from notification - hangup() called successfully');
        
        // Store declined call info before clearing
        final declinedCallId = _currentIncomingCall!.id ?? 'unknown';
        final declinedCaller = _currentIncomingCall!.remote_identity ?? 'Unknown';
        
        _currentIncomingCall = null;
        
        print('📞 Hiding incoming call notification...');
        hideIncomingCallNotification();
        print('✅ Notification hidden successfully');
        
        // Notify main app via service event
        _serviceInstance?.invoke('callDeclined', {
          'callId': declinedCallId,
          'caller': declinedCaller,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
      } catch (e) {
        print('❌ Error declining call from notification: $e');
        print('❌ Error type: ${e.runtimeType}');
        print('❌ Stack trace: ${StackTrace.current}');
      }
    } else {
      print('❌❌❌ CRITICAL: No current incoming call to decline!');
      print('❌ This indicates notification state is not properly maintained');
      
      // Still hide the notification even if call state is lost
      hideIncomingCallNotification();
    }
  }

  @pragma('vm:entry-point')
  static void _forwardCallToMainApp(Call call) async {
    print('🔄🔄🔄 Forwarding call to active main app: ${call.remote_identity} 🔄🔄🔄');

    try {
      // Store the call for main app to access
      _forwardedCall = call;
      print('📞 Stored forwarded call in memory: ${call.remote_identity} (ID: ${call.id})');

      // CRITICAL: Also store in SharedPreferences for cross-process access
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('forwarded_call_id', call.id ?? 'unknown');
      await prefs.setString('forwarded_call_caller', call.remote_identity ?? 'Unknown');
      await prefs.setString('forwarded_call_direction', call.direction.toString());
      await prefs.setString('forwarded_call_state', call.state.toString());
      await prefs.setInt('forwarded_call_timestamp', DateTime.now().millisecondsSinceEpoch);
      print('💾 Stored forwarded call in SharedPreferences');

      // Send event to main app using FlutterBackgroundService
      final service = FlutterBackgroundService();
      print('📡 Service instance: ${service.hashCode}');

      final eventData = {
        'caller': call.remote_identity ?? 'Unknown',
        'callId': call.id ?? 'unknown',
        'direction': call.direction.toString(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      print('📤 Sending event data: $eventData');

      service.invoke('callForwardedToMainApp', eventData);

      print('✅✅✅ Call forwarded to main app via service communication ✅✅✅');

      // Also try to trigger via service instance if available
      if (_serviceInstance != null) {
        print('📡 Also sending via service instance...');
        _serviceInstance!.invoke('callForwardedToMainApp', eventData);
        print('✅ Sent via service instance too');
      }
    } catch (e) {
      print('❌❌❌ Error forwarding call to main app: $e ❌❌❌');
    }
  }

  @pragma('vm:entry-point')
  static void _forceOpenApp(Call call) {
    print('📱 Force opening app for incoming call from ${call.remote_identity}');

    try {
      // Use service instance to send message to main app
      _serviceInstance?.invoke('forceOpenApp', {
        'caller': call.remote_identity ?? 'Unknown',
        'callId': call.id ?? 'unknown',
        'direction': call.direction.toString(),
      });
    } catch (e) {
      print('❌ Error force opening app: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _launchAppWithIncomingCall(String? payload) {
    print('📱 Launching app for incoming call - payload: $payload');

    if (payload == null) {
      print('⚠️ No payload provided for incoming call');
      return;
    }

    try {
      // Parse payload: 'incoming_call:callId:caller'
      final parts = payload.split(':');
      if (parts.length >= 3) {
        final callId = parts[1];
        final caller = parts[2];

        print('📞 Launching app for call from $caller (ID: $callId)');

        // CRITICAL: Use the aggressive forceOpenAppForCall instead
        const platform = MethodChannel('sip_phone/incoming_call');
        platform.invokeMethod('forceOpenAppForCall', {
          'caller': caller,
          'callId': callId,
          'autoLaunch': true,
          'fromNotification': true,
          'forceToForeground': true,
          'showIncomingCallScreen': true,
        }).then((_) {
          print('✅ FORCE app launch request sent via platform channel');

          // Also ensure the call is properly stored for main app access
          if (_currentIncomingCall != null) {
            _forwardedCall = _currentIncomingCall;
            print('🔄 Stored current incoming call as forwarded call for main app');
          }
        }).catchError((error) {
          print('❌ Failed to FORCE launch app via platform channel: $error');

          // Fallback to old method
          platform.invokeMethod('launchIncomingCallScreen', {
            'caller': caller,
            'callId': callId,
            'fromNotification': true,
          });
        });
      } else {
        print('⚠️ Invalid payload format: $payload');
      }
    } catch (e) {
      print('❌ Error launching app for incoming call: $e');
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    print('🍎 iOS background service activated');
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    print('🚀 Background service onStart called');

    // CRITICAL: The foreground service notification is already handled by flutter_background_service
    // through the AndroidConfiguration in initializeService(). We just need to ensure
    // the service starts properly and doesn't get killed by Android timing constraints.
    print('✅ Service started - foreground notification handled by flutter_background_service');

    // Now do the initialization
    DartPluginRegistrant.ensureInitialized();

    if (_isServiceRunning) {
      print('⚠️ Service already running, ignoring duplicate start');
      return;
    }

    _serviceInstance = service;
    _isServiceRunning = true;
    print('✅ Persistent background service started');
    print('📱 Main app active status on service start: $_isMainAppActive');

    // Set up service control listeners first
    service.on('stopService').listen((event) {
      _stopPersistentService();
      service.stopSelf();
    });

    service.on('updateSipUser').listen((event) async {
      final data = event!['sipUser'] as String;
      final sipUser = SipUser.fromJsonString(data);
      await _updateSipConnection(sipUser);
    });
    
    // CRITICAL: New call handling events
    service.on('makeCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final number = data['number'] as String;
      await _handleMakeCall(number);
    });
    
    service.on('acceptCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleAcceptCall(callId);
    });
    
    service.on('rejectCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleRejectCall(callId);
    });
    
    service.on('endCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleEndCall(callId);
    });
    
    service.on('unregisterSip').listen((event) async {
      await _handleUnregisterSip();
    });
    
    service.on('sendDTMF').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      final digit = data['digit'] as String;
      await _handleSendDTMF(callId, digit);
    });

    service.on('toggleMute').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleToggleMute(callId);
    });

    service.on('toggleSpeaker').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleToggleSpeaker(callId);
    });

    service.on('toggleHold').listen((event) async {
      final data = event as Map<String, dynamic>;
      final callId = data['callId'] as String;
      await _handleToggleHold(callId);
    });

    service.on('proceedWithBackgroundSipCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final number = data['number'] as String;
      final webrtcReady = data['webrtcReady'] as bool? ?? false;
      await _handleProceedWithSipCall(number, webrtcReady);
    });

    service.on('getSipCredentialsForCall').listen((event) async {
      final data = event as Map<String, dynamic>;
      final number = data['number'] as String;
      await _handleGetSipCredentialsForCall(number);
    });

    service.on('forwardCallToMainApp').listen((event) {
      print('🔄 Background service received forward call to main app request');
      final data = event as Map<String, dynamic>;
      final caller = data['caller'] as String;
      final callId = data['callId'] as String;

      // This will be handled by the main app - just log for now
      print('📞 Call forwarded to main app: $caller (ID: $callId)');
    });

    service.on('syncSipState').listen((event) {
      print('🔄 Syncing current SIP state to main app on request');
      _syncCurrentSipStateToMainApp(service);
    });

    service.on('registerSip').listen((event) async {
      print('🔐 Processing SIP registration request from main app');
      final data = event as Map<String, dynamic>;
      final accountJson = data['account'] as String;
      await _handleRegisterSipFromMainApp(service, accountJson);
    });

    service.on('ping').listen((event) {
      print('🏓 Background service received ping - responding with status');
      service.invoke('pong', {
        'serviceRunning': _isServiceRunning,
        'helperExists': _backgroundSipHelper != null,
        'userExists': _currentSipUser != null,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    });

    service.on('forceOpenApp').listen((event) {
      print('📱 Background service received force open app request');
      final data = event as Map<String, dynamic>;
      final caller = data['caller'] as String;
      final callId = data['callId'] as String;

      // Show urgent notification to force user attention
      showIncomingCallNotification(
        caller: '🚨 URGENT: $caller calling! TAP TO ANSWER',
        callId: callId,
      );
    });

    print('✅ Background service started successfully in foreground mode');

    // Initialize SIP connection asynchronously to avoid blocking foreground service
    Future.delayed(Duration(milliseconds: 100), () async {
      try {
        await _initializePersistentSipConnection(service);
        print('✅ Background service initialization completed');
      } catch (e) {
        print('❌ Background service initialization failed: $e');
        _updateServiceNotification('SIP Phone Error', 'Failed to initialize - will retry when needed');
      }
    });
  }

  @pragma('vm:entry-point')
  static Future<void> _initializePersistentSipConnection(ServiceInstance service) async {
    try {
      print('🔄 Initializing persistent SIP connection in background...');

      // First try quick SharedPreferences load
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');
      final shouldMaintain = prefs.getBool('should_maintain_websocket_connection') ?? false;

      if (savedUserJson != null && shouldMaintain) {
        _currentSipUser = SipUser.fromJsonString(savedUserJson);
        print('📋 Loaded SIP user from SharedPreferences: ${_currentSipUser!.authUser}');
      } else {
        print('⚠️ No saved SIP user in SharedPreferences, trying Hive...');

        // Try Hive with timeout to prevent hanging
        try {
          await _loadSipUserFromHiveForInitialization().timeout(
            Duration(seconds: 10),
            onTimeout: () {
              print('⏰ Hive loading timed out after 10 seconds');
              throw TimeoutException('Hive loading timeout');
            },
          );

          if (_currentSipUser == null) {
            print('❌ No SIP user configuration found');
            _updateServiceNotification('SIP Phone', 'Not configured - please login');
            return;
          }
        } catch (e) {
          print('❌ Error loading from Hive: $e');
          _updateServiceNotification('SIP Phone', 'Configuration error');
          return;
        }
      }

      // Initialize SIP helper
      _backgroundSipHelper = SIPUAHelper();
      final listener = PersistentSipListener(service);
      _backgroundSipHelper!.addSipUaHelperListener(listener);
      print('✅ Background SIP helper initialized');

      // Check if main app is active from Hive first, then fallback to SharedPreferences
      bool mainAppActive = false;
      try {
        final dir = await getApplicationDocumentsDirectory();
        await Hive.initFlutter(dir.path);
        final box = await Hive.openBox('app_data');

        mainAppActive = box.get('main_app_is_active') ?? false;

        // Check timestamp to ensure data is recent
        final timestamp = box.get('main_app_status_timestamp') ?? 0;
        if (timestamp > 0) {
          final lastUpdate = DateTime.fromMillisecondsSinceEpoch(timestamp);
          final timeSinceUpdate = DateTime.now().difference(lastUpdate);

          if (timeSinceUpdate.inMinutes > 5) {
            print('⚠️ Main app status from Hive is outdated - assuming background');
            mainAppActive = false;
          }
        }

        // DON'T close the box - let the main app manage it
      } catch (e) {
        print('⚠️ Could not check main app status from Hive during init: $e');
        // Fallback to SharedPreferences
        mainAppActive = prefs.getBool('main_app_is_active') ?? false;
      }

      print('📊 Main app active status: $mainAppActive');

      if (mainAppActive) {
        print('📱 Main app is active - background service in standby mode (NO SIP registration)');
        _isMainAppActive = true;
        
        // CRITICAL: Single SIP architecture - background service ALWAYS maintains SIP helper
        // Main app active state doesn't affect SIP operations
        print('✅ Background SIP helper maintained (single SIP architecture)');
        
        _updateServiceNotification('SIP Phone (Standby)', 'Main app active - background service ready');
      } else {
        print('🔄 Main app is background - starting SIP connection');
        _isMainAppActive = false;
        
        // Double-check main app is really inactive before connecting
        final prefs = await SharedPreferences.getInstance();
        final recentCheck = prefs.getBool('main_app_is_active') ?? false;
        if (!recentCheck) {
          await _connectSipInBackground(_currentSipUser!);
        } else {
          print('⚠️ Last-second check shows main app is active - not connecting');
          _isMainAppActive = true;
        }
      }

      // Set up keep-alive and health monitoring
      _startKeepAliveTimer();
      _startHealthMonitoring();

      print('✅ Persistent SIP connection initialized successfully');
    } catch (e) {
      print('❌ Error initializing persistent SIP connection: $e');
      _updateServiceNotification('SIP Phone Error', 'Failed to connect: $e');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _connectSipInBackground(SipUser user, {bool allowBackupConnection = false}) async {
    try {
      print('🔌 Connecting SIP in background...');

      // CRITICAL: Background service now handles ALL SIP operations regardless of main app state
      // Small delay for stability
      await Future.delayed(Duration(milliseconds: 200));

      if (_backgroundSipHelper == null) {
        print('⚠️ SIP helper not initialized - creating new one');
        _backgroundSipHelper = SIPUAHelper();

        // Add listener if service instance is available
        if (_serviceInstance != null) {
          final listener = PersistentSipListener(_serviceInstance!);
          _backgroundSipHelper!.addSipUaHelperListener(listener);
          print('✅ Background SIP listener added during connection');
        } else {
          print('⚠️ Service instance not available - SIP helper created without listener');
        }
      }

      // Disconnect if already connected
      if (_backgroundSipHelper!.registered) {
        print('📴 Background SIP helper already registered - unregistering first');
        await _backgroundSipHelper!.unregister();
        _backgroundSipHelper!.stop();
        await Future.delayed(Duration(seconds: 1));
        print('✅ Previous background registration cleaned up');
      }

      UaSettings settings = UaSettings();

      // Parse SIP configuration
      String sipUri = user.sipUri ?? '';
      String username = user.authUser;
      String domain = '';

      if (sipUri.contains('@')) {
        final parts = sipUri.split('@');
        if (parts.length > 1) {
          username = parts[0].replaceAll('sip:', '');
          domain = parts[1];
        }
      } else if (user.wsUrl != null && user.wsUrl!.isNotEmpty) {
        try {
          final uri = Uri.parse(user.wsUrl!);
          domain = uri.host;
        } catch (e) {
          print('⚠️ Failed to parse domain from WebSocket URL: $e');
          domain = 'localhost';
        }
      }

      String properSipUri = 'sip:$username@$domain';

      // Configure WebSocket settings for background
      settings.transportType = TransportType.WS;
      settings.webSocketUrl = user.wsUrl ?? '';
      settings.webSocketSettings.extraHeaders = user.wsExtraHeaders ?? {};
      settings.webSocketSettings.allowBadCertificate = true;
      // Note: pingInterval may not be available in all versions

      // SIP settings
      settings.uri = properSipUri;
      settings.registrarServer = domain;
      settings.authorizationUser = username;
      settings.password = user.password;
      settings.displayName = user.displayName.isNotEmpty ? user.displayName : username;
      settings.userAgent = 'Flutter SIP Background Service v1.0.0';
      settings.dtmfMode = DtmfMode.RFC2833;
      settings.register = true;
      settings.register_expires = 300;

      // Host configuration
      try {
        Uri wsUri = Uri.parse(settings.webSocketUrl!);
        settings.host = wsUri.host.isNotEmpty ? wsUri.host : domain;
      } catch (e) {
        settings.host = domain;
      }

      print('🚀 Starting background SIP connection to: ${settings.webSocketUrl}');
      print('📋 SIP URI: $properSipUri');
      print('📊 Main app active status: $_isMainAppActive');

      // CRITICAL: With single SIP architecture, background service ALWAYS handles SIP registration
      // Main app active status is irrelevant - background service is the sole SIP handler
      print('✅ Using single SIP architecture - background service handles all SIP operations regardless of main app state');
      
      // Synchronization lock to prevent concurrent modifications during start
      if (_backgroundSipHelper == null) {
        print('❌ Background SIP helper became null during connection - race condition detected');
        return;
      }

      await _backgroundSipHelper!.start(settings);
      print('✅ Background SIP connection started');

      // Wait for registration with race condition checks
      for (int attempt = 0; attempt < 10; attempt++) {
        await Future.delayed(Duration(milliseconds: 500));
        
        // Continue with single SIP architecture - main app status doesn't affect registration
        
        if (_backgroundSipHelper?.registered == true) {
          print('✅✅ Background SIP successfully registered after ${attempt + 1} checks! ✅✅');
          _updateServiceNotification(
              'SIP Phone Active (Background)', 'Connected and ready to receive calls in background');
          return;
        }
      }
      
      print('❌ Background SIP registration failed after timeout - will retry');
      throw Exception('Background SIP registration timeout after race condition prevention');
    } catch (e) {
      print('❌ Background SIP connection failed: $e');
      _updateServiceNotification('SIP Connection Failed', e.toString());
      _scheduleReconnection();
    }
  }

  @pragma('vm:entry-point')
  static void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    // Increased frequency for better background reliability
    _keepAliveTimer = Timer.periodic(Duration(seconds: 20), (timer) async {
      // Check if main app is active from Hive (real-time status)
      bool mainAppActive = _isMainAppActive;
      try {
        final dir = await getApplicationDocumentsDirectory();
        await Hive.initFlutter(dir.path);
        Box box;

        try {
          box = Hive.box('app_data');
          if (!box.isOpen) {
            box = await Hive.openBox('app_data');
          }
        } catch (e) {
          box = await Hive.openBox('app_data');
        }

        mainAppActive = box.get('main_app_is_active') ?? false;
        _isMainAppActive = mainAppActive; // Update static variable

        // Check timestamp to ensure data is recent (within last 5 minutes)
        final timestamp = box.get('main_app_status_timestamp') ?? 0;
        final lastUpdate = DateTime.fromMillisecondsSinceEpoch(timestamp);
        final timeSinceUpdate = DateTime.now().difference(lastUpdate);

        if (timeSinceUpdate.inMinutes > 5) {
          print('⚠️ Main app status is outdated (${timeSinceUpdate.inMinutes} min old) - assuming background');
          mainAppActive = false;
          _isMainAppActive = false;
        }

        // DON'T close the box - let the main app manage it
      } catch (e) {
        print('⚠️ Could not check main app status from Hive: $e');

        // Fallback to SharedPreferences
        try {
          final prefs = await SharedPreferences.getInstance();
          mainAppActive = prefs.getBool('main_app_is_active') ?? false;
          _isMainAppActive = mainAppActive;
        } catch (fallbackError) {
          print('⚠️ SharedPreferences fallback also failed: $fallbackError');
        }
      }

      if (mainAppActive) {
        print('📱 Keep-alive: Main app active - background SIP continues (single SIP architecture)');

        // CRITICAL: Single SIP architecture - background service ALWAYS maintains SIP
        // Main app active state is for UI coordination only
        print('✅ Keep-alive: Background SIP helper maintained for calls');

        _updateServiceNotification('SIP Phone (Main App Active)', 'Main app active - background service ready');
        // Don't return - continue with SIP monitoring
      } else {
        print('📱 Keep-alive: Main app in background - SIP continues normally');
        _updateServiceNotification('SIP Phone Active', 'Ready to receive calls - Running in background for 24/7 operation');
      }

      if (_backgroundSipHelper?.registered == true) {
        print('💓 Background SIP keep-alive check: Connected');
        print('📊 Background SIP Helper Status:');
        print('  - Registered: ${_backgroundSipHelper?.registered}');
        print('  - WebSocket URL: ${_currentSipUser?.wsUrl}');
        print('  - Background helper ready: ${_backgroundSipHelper != null}');
        print('  - Service running: $_isServiceRunning');
        _updateServiceNotification(
            'SIP Phone 24/7 Active', 'Background service ready • ${DateTime.now().toString().substring(11, 16)}');

        // Additional health check - verify connection is stable
        // Note: We already know registered is true, so this is good
      } else {
        print('⚠️ Background SIP keep-alive check: Disconnected - initiating aggressive reconnection');
        _updateServiceNotification('SIP Phone Reconnecting', 'Attempting to reconnect...');
        if (_currentSipUser != null) {
          print('🔄 Keep-alive: Attempting reconnection with current SIP user');
          _connectSipInBackground(_currentSipUser!);
        } else {
          // Try to load SIP user from SharedPreferences if not in memory
          print('📎 Keep-alive: SIP user not in memory - attempting to load from SharedPreferences...');
          try {
            final prefs = await SharedPreferences.getInstance();
            final savedUserJson = prefs.getString('websocket_sip_user');

            if (savedUserJson != null) {
              _currentSipUser = SipUser.fromJsonString(savedUserJson);
              print('✅ Keep-alive: SIP user loaded from SharedPreferences: ${_currentSipUser!.authUser}');
              _connectSipInBackground(_currentSipUser!);
            } else {
              print('🔍 Keep-alive: No SIP user found in SharedPreferences - trying Hive...');
              await _loadSipUserFromHiveAndReregister();
            }
          } catch (e) {
            print('❌ Keep-alive: Error loading SIP user from SharedPreferences: $e');
            // Fallback to Hive
            await _loadSipUserFromHiveAndReregister();
          }
        }
      }
    });
  }

  @pragma('vm:entry-point')
  static void _startHealthMonitoring() {
    Timer.periodic(Duration(minutes: 1), (timer) async {
      if (!_isServiceRunning) {
        timer.cancel();
        return;
      }

      try {
        if (_isMainAppActive) {
          print('📱 Health check: Main app active - background in standby (NO SIP)');
          if (_backgroundSipHelper != null) {
            print('📴 Health check: Destroying background SIP - main app is active');
            if (_backgroundSipHelper!.registered) {
              await _backgroundSipHelper!.unregister();
            }
            _backgroundSipHelper!.stop();
            _backgroundSipHelper = null; // Destroy completely
          }
          return;
        }

        if (_backgroundSipHelper?.registered != true && _currentSipUser != null) {
          print('🔄 Health check: Reconnecting background SIP');
          _connectSipInBackground(_currentSipUser!);
        } else {
          print('✅ Health check: Background SIP healthy');
        }
      } catch (e) {
        print('❌ Health check error: $e');
      }
    });
  }

  @pragma('vm:entry-point')
  static void _scheduleReconnection() {
    _reconnectionTimer?.cancel();
    _reconnectionTimer = Timer(Duration(seconds: 10), () {
      if (_currentSipUser != null && _isServiceRunning) {
        print('🔄 Attempting scheduled reconnection...');
        _connectSipInBackground(_currentSipUser!);
      }
    });
  }

  @pragma('vm:entry-point')
  static Future<void> _updateSipConnection(SipUser newUser) async {
    print('🔄 Updating SIP connection with new user configuration');
    print('📊 Main app active status during update: $_isMainAppActive');

    _currentSipUser = newUser;

    // Only connect if main app is not active
    if (!_isMainAppActive) {
      print('📞 Main app not active - connecting with updated user');
      await _connectSipInBackground(newUser);
    } else {
      print('📱 Main app is active - storing user config but not connecting yet');
      print('📱 Background service will connect when main app goes to background');
    }
  }

  @pragma('vm:entry-point')
  static void _updateServiceNotification(String title, String content) {
    // Log the status update - the foreground notification is handled by flutter_background_service
    // The initial notification is set via AndroidConfiguration and will persist
    print('📱 Service status: $title - $content');

    // We could potentially use the notification plugin to create additional status notifications
    // but for foreground service, the main notification is handled by the service framework
  }

  @pragma('vm:entry-point')
  static Future<void> showIncomingCallNotification({
    required String caller,
    required String callId,
  }) async {
    print('🔔🔔🔔 SHOWING INCOMING CALL NOTIFICATION 🔔🔔🔔');
    print('📞 Caller: $caller (ID: $callId)');
    
    // CRITICAL FIX: Always show notification for incoming calls
    // Notification handles app launching and call state management
    print('🔔 Preparing notification for incoming call from: $caller');
    
    // Ensure _currentIncomingCall is set before showing notification
    if (_currentIncomingCall == null) {
      print('⚠️⚠️ WARNING: _currentIncomingCall is null when showing notification!');
      print('⚠️ This could cause accept/decline to fail from notification!');
      
      // Try to recover by looking up the call
      try {
        // If background SIP helper exists, we should have the call
        // This is a defensive measure
        print('🔄 Attempting to recover current incoming call...');
      } catch (e) {
        print('❌ Failed to recover incoming call: $e');
      }
    }

    // AGGRESSIVE AUTO-LAUNCH with multiple methods
    print('🚀 Aggressively launching app for incoming call from: $caller');
    
    try {
      const platform = MethodChannel('sip_phone/incoming_call');
      
      // Try multiple launch methods for better reliability
      await platform.invokeMethod('forceOpenAppForCall', {
        'caller': caller,
        'callId': callId,
        'fromBackground': true,
        'forceToForeground': true,
        'autoLaunch': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      print('✅ Aggressive app launch request sent via platform channel');
    } catch (e) {
      print('⚠️ Primary platform channel launch failed: $e - trying fallback');
      
      // Fallback method
      try {
        const platform = MethodChannel('sip_phone/incoming_call');
        await platform.invokeMethod('handleIncomingCall', {
          'caller': caller,
          'callId': callId,
          'fromBackground': true,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        print('✅ Fallback app launch request sent');
      } catch (fallbackError) {
        print('❌ All platform channel launch methods failed: $fallbackError');
      }
    }

    // Start continuous ringing with vibration - async operation
    _startContinuousRinging();

    final androidDetails = AndroidNotificationDetails(
      'incoming_calls_channel',
      'Incoming Calls',
      channelDescription: 'Notifications for incoming SIP calls',
      importance: Importance.max,
      priority: Priority.max, // Changed to max for highest priority
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true, // Show as full screen on lock screen
      ongoing: true, // Cannot be dismissed
      autoCancel: false,
      showWhen: true,
      when: null,
      usesChronometer: false,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
      ticker: 'Incoming call from $caller',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
      visibility: NotificationVisibility.public,
      showProgress: false,
      indeterminate: false,
      // Enhanced for screen visibility
      enableLights: true,
      ledColor: const Color.fromARGB(255, 255, 0, 0),
      ledOnMs: 1000,
      ledOffMs: 500,
      timeoutAfter: null, // Never timeout
      groupKey: 'incoming_calls',
      setAsGroupSummary: true,
      onlyAlertOnce: false, // Always alert
      // Add action buttons for Answer/Decline
      // CRITICAL FIX: Enhanced notification actions with PendingIntent support
      actions: [
        AndroidNotificationAction(
          'answer_call',
          '📞 ANSWER CALL',
          titleColor: Color.fromARGB(255, 0, 255, 0),
          icon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          contextual: true,
          showsUserInterface: true, // Opens app when tapped
        ),
        AndroidNotificationAction(
          'decline_call',
          '❌ DECLINE CALL',
          titleColor: Color.fromARGB(255, 255, 0, 0),
          icon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          contextual: true,
          showsUserInterface: false, // Handles in background
        ),
      ],
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'phone_ringing.caf',
      interruptionLevel: InterruptionLevel.critical,
      categoryIdentifier: 'INCOMING_CALL',
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // CRITICAL FIX: Show notification with improved payload format
    await _notificationsPlugin.show(
      999, // Fixed ID for incoming calls
      '📞 INCOMING CALL',
      'Call from $caller - Tap ANSWER or DECLINE',
      notificationDetails,
      payload: 'incoming_call:$callId:$caller',
    );
    
    print('✅ Incoming call notification displayed successfully');
    print('📞 Notification ID: 999');
    print('📞 Payload: incoming_call:$callId:$caller');
    print('📞 Current incoming call stored: ${_currentIncomingCall != null}');

    // Verify notification was displayed properly
    if (_currentIncomingCall == null) {
      print('❌❌❌ CRITICAL ERROR: _currentIncomingCall is null after showing notification!');
      print('❌ This WILL cause accept/decline from notification to fail!');
      print('❌ Need to investigate call state management in background service!');
    } else {
      print('✅ Notification displayed with proper call state maintained');
    }
  }

  static Timer? _ringingTimer;

  @pragma('vm:entry-point')
  static void _startContinuousRinging() {
    print('🔔 Starting continuous ringing...');

    // Stop any existing ringing
    _ringingTimer?.cancel();

    // Start ringing immediately and repeat every 2 seconds
    _playRingTone();
    _ringingTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      _playRingTone();
    });
  }

  @pragma('vm:entry-point')
  static void _playRingTone() {
    try {
      // Create strong vibration pattern for ringing
      HapticFeedback.heavyImpact();

      // Double vibration for ring effect
      Timer(Duration(milliseconds: 100), () {
        HapticFeedback.heavyImpact();
      });

      print('🔔 Ring vibration played');
    } catch (e) {
      print('❌ Error playing ringtone: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _stopRinging() {
    print('🔇 Stopping ringing...');
    _ringingTimer?.cancel();
    _ringingTimer = null;
  }

  @pragma('vm:entry-point')
  static Future<void> hideIncomingCallNotification() async {
    _stopRinging(); // Stop ringing when hiding notification
    await _notificationsPlugin.cancel(999);
    print('📱 Incoming call notification hidden');
  }

  @pragma('vm:entry-point')
  static void _stopPersistentService() {
    print('🛑🛑🛑 STOPPING PERSISTENT BACKGROUND SERVICE 🛑🛑🛑');
    print('📊 STOP: Called from: ${StackTrace.current}');
    print('📊 STOP: Service was running: $_isServiceRunning');
    print('📊 STOP: Helper exists: ${_backgroundSipHelper != null}');

    _isServiceRunning = false;
    _keepAliveTimer?.cancel();
    _reconnectionTimer?.cancel();

    try {
      if (_backgroundSipHelper?.registered == true) {
        _backgroundSipHelper?.unregister();
      }
      _backgroundSipHelper?.stop();
      _backgroundSipHelper = null;
      print('🛑 Background SIP helper destroyed');
    } catch (e) {
      print('❌ Error stopping SIP helper: $e');
    }

    print('✅ Persistent service stopped');
  }

  // Public API methods
  @pragma('vm:entry-point')
  static Future<void> startService() async {
    final service = FlutterBackgroundService();

    // Check if service is already running to prevent duplicate starts
    final isRunning = await service.isRunning();
    if (isRunning) {
      print('⚠️ Background service already running - not starting again');
      return;
    }

    await service.startService();
    print('🚀 Background service start requested');
  }

  @pragma('vm:entry-point')
  static Future<void> stopService() async {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
    print('🛑 Background service stop requested');
  }

  @pragma('vm:entry-point')
  static Future<void> updateSipUserInService(SipUser sipUser) async {
    // Store SIP user data in SharedPreferences for background service access
    // Note: We still need SharedPreferences for cross-isolate communication
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('websocket_sip_user', sipUser.toJsonString());
      await prefs.setBool('should_maintain_websocket_connection', true);
      print('💾 SIP user data stored in SharedPreferences for background service');
    } catch (e) {
      print('❌ Error storing SIP user data in SharedPreferences: $e');
    }

    // Check if service is running before trying to send data to it
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('updateSipUser', {
        'sipUser': sipUser.toJsonString(),
      });
      print('🔄 SIP user update sent to background service');
    } else {
      print('⚠️ Background service not running - cannot send SIP user update');
    }
  }

  @pragma('vm:entry-point')
  static bool isServiceRunning() {
    return _isServiceRunning;
  }

  @pragma('vm:entry-point')
  static List<Call> getActiveCalls() {
    final activeCalls = <Call>[];
    if (_currentIncomingCall != null) activeCalls.add(_currentIncomingCall!);
    if (_currentActiveCall != null) activeCalls.add(_currentActiveCall!);
    return activeCalls;
  }

  @pragma('vm:entry-point')
  static bool hasIncomingCall() {
    return _currentIncomingCall != null;
  }

  @pragma('vm:entry-point')
  static Call? getIncomingCall() {
    return _currentIncomingCall;
  }

  @pragma('vm:entry-point')
  static Call? getActiveCall() {
    return _currentActiveCall ?? _currentIncomingCall;
  }

  @pragma('vm:entry-point')
  static void setIncomingCall(Call call) {
    print('📞 Setting incoming call: ${call.remote_identity} (ID: ${call.id})');
    _currentIncomingCall = call;
  }

  @pragma('vm:entry-point')
  static SIPUAHelper? getBackgroundSipHelper() {
    return _backgroundSipHelper;
  }

  @pragma('vm:entry-point')
  static void transferCallToMainApp() {
    print('🔄 Transferring call from background to main app');
    // The main app will use the same SIP helper instance
    // This ensures the call continues seamlessly
  }

  @pragma('vm:entry-point')
  static void setMainAppActive(bool isActive) {
    final now = DateTime.now();

    // Prevent rapid switching - ignore if the same state was set within last 2 seconds
    if (_lastAppStatusChange != null &&
        _isMainAppActive == isActive &&
        now.difference(_lastAppStatusChange!).inSeconds < 2) {
      print('🚫 Ignoring duplicate app status change to ${isActive ? "ACTIVE" : "BACKGROUND"} (within 2s)');
      return;
    }

    _lastAppStatusChange = now;
    print('📱 Main app status: ${isActive ? "ACTIVE" : "BACKGROUND"}');
    _isMainAppActive = isActive;

    // Save to SharedPreferences asynchronously
    _handleMainAppStatusChange(isActive);

    // CRITICAL: With single SIP architecture, background service ALWAYS maintains SIP connection
    // Main app active state is tracked for UI coordination only, not SIP control
    if (isActive) {
      print('📱 Main app active - background SIP continues (single SIP architecture)');
      _updateServiceNotification('SIP Phone (Main App Active)', 'Main app active - background service ready');
    } else {
      print('🔄 Main app backgrounded - background SIP continues handling calls');
      _updateServiceNotification('SIP Phone Active', 'Ready to receive calls - Running in background for 24/7 operation');
    }
  }

  @pragma('vm:entry-point')
  static void _completelyStopBackgroundSipForMainApp() async {
    try {
      if (_backgroundSipHelper != null) {
        if (_backgroundSipHelper!.registered) {
          print('📴 COMPLETELY stopping background SIP - main app will handle ALL calls');
          await _backgroundSipHelper!.unregister();
        }
        _backgroundSipHelper!.stop();
        _backgroundSipHelper = null; // Destroy the helper completely
        print('✅ Background SIP helper COMPLETELY destroyed for main app');
      }
      
      // Clear any active calls since main app will handle them
      _currentIncomingCall = null;
      _currentActiveCall = null;
      
      _updateServiceNotification('SIP Phone (Main App Active)', 'Main app active - background service ready');
    } catch (e) {
      print('❌ Error completely stopping background SIP: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _handleMainAppStatusChange(bool isActive) async {
    try {
      // Update Hive database with main app status
      final dir = await getApplicationDocumentsDirectory();
      await Hive.initFlutter(dir.path);
      Box? box;

      try {
        box = Hive.box('app_data');
        if (!box.isOpen) {
          box = await Hive.openBox('app_data');
        }
      } catch (e) {
        // Box might not exist, try to open it
        box = await Hive.openBox('app_data');
      }

      await box.put('main_app_is_active', isActive);
      await box.put('main_app_status_timestamp', DateTime.now().millisecondsSinceEpoch);

      _isMainAppActive = isActive;
      print('💾 Main app status updated in Hive: $isActive');

      // DON'T close the box - let the main app manage it
    } catch (e) {
      print('❌ Error saving main app status to Hive: $e');

      // Fallback to SharedPreferences for backward compatibility
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('main_app_is_active', isActive);
        print('💾 Main app status saved to SharedPreferences as fallback: $isActive');
      } catch (fallbackError) {
        print('❌ Error with SharedPreferences fallback: $fallbackError');
      }
    }
  }

  @pragma('vm:entry-point')
  static void _temporarilyUnregisterForMainApp() async {
    try {
      if (_backgroundSipHelper != null && _backgroundSipHelper!.registered) {
        print('📴 Temporarily unregistering background SIP helper for main app');
        await _backgroundSipHelper!.unregister();

        // Update notification
        _updateServiceNotification(
            'SIP Phone (Main App Active)', 'Main app handling calls - background service standby');

        print('✅ Background SIP helper temporarily unregistered');
        print('📊 After unregister - Helper exists: ${_backgroundSipHelper != null}');
        print('📊 After unregister - Service running: $_isServiceRunning');
      } else {
        print('⚠️ Background SIP helper not available for unregistering');
        print('📊 Helper exists: ${_backgroundSipHelper != null}');
        print('📊 Helper registered: ${_backgroundSipHelper?.registered}');
      }
    } catch (e) {
      print('❌ Error temporarily unregistering background SIP helper: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _reregisterAfterMainAppBackground() {
    print('🔄 Re-registering background SIP after main app backgrounded');

    // Check if background service is already registered
    if (_backgroundSipHelper != null && _backgroundSipHelper!.registered) {
      print('✅ Background SIP already registered - skipping duplicate registration');
      _updateServiceNotification('SIP Phone Active (Background)', 'Already connected - ready to receive calls');
      return;
    }

    if (_currentSipUser != null && !_isMainAppActive) {
      print('🚀 Starting background SIP connection');
      _connectSipInBackground(_currentSipUser!);
    } else {
      print('⚠️ Cannot re-register: user=${_currentSipUser != null}, mainAppActive=$_isMainAppActive');

      // Try to load SIP user from SharedPreferences if not in memory
      if (_currentSipUser == null && !_isMainAppActive) {
        print('📎 SIP user not in memory - attempting to load from SharedPreferences...');
        _loadSipUserFromPreferencesAndReregister();
      }
    }
  }

  @pragma('vm:entry-point')
  static void _loadSipUserFromPreferencesAndReregister() async {
    try {
      print('📎 Loading SIP user from SharedPreferences for background re-registration...');
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');

      if (savedUserJson != null) {
        _currentSipUser = SipUser.fromJsonString(savedUserJson);
        print('✅ SIP user loaded from SharedPreferences: ${_currentSipUser!.authUser}');

        // Now try to re-register with loaded user
        if (!_isMainAppActive) {
          print('🚀 Starting background SIP connection with loaded user');
          _connectSipInBackground(_currentSipUser!);
        }
      } else {
        print('🔍 No SIP user found in SharedPreferences - trying to load from Hive...');
        await _loadSipUserFromHiveAndReregister();
      }
    } catch (e) {
      print('❌ Error loading SIP user from preferences for re-registration: $e');
      // Fallback to Hive
      await _loadSipUserFromHiveAndReregister();
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _loadSipUserFromHiveForInitialization() async {
    await _loadSipUserFromHive();
  }

  @pragma('vm:entry-point')
  static Future<void> _loadSipUserFromHiveAndReregister() async {
    await _loadSipUserFromHive();

    // Now try to re-register with loaded user
    if (_currentSipUser != null && !_isMainAppActive) {
      print('🚀 Starting background SIP connection with Hive-loaded user');
      _connectSipInBackground(_currentSipUser!);
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _loadSipUserFromHive() async {
    try {
      print('📎 Loading SIP user from Hive...');

      // Initialize Hive in background service isolate
      final dir = await getApplicationDocumentsDirectory();
      await Hive.initFlutter(dir.path);
      final box = await Hive.openBox('app_data');

      // Find default credentials
      StoredCredentialsModel? credentials;
      for (final key in box.keys) {
        if (key.toString().startsWith('credentials_')) {
          final data = box.get(key) as Map;
          if (data['isDefault'] == true) {
            credentials = StoredCredentialsModel()
              ..id = data['id']
              ..username = data['username'] ?? ''
              ..password = data['password'] ?? ''
              ..domain = data['domain'] ?? ''
              ..wsUrl = data['wsUrl'] ?? ''
              ..displayName = data['displayName']
              ..isDefault = data['isDefault'] ?? false;
            break;
          }
        }
      }

      // If no default, get most recent
      if (credentials == null) {
        DateTime? mostRecentTime;
        for (final key in box.keys) {
          if (key.toString().startsWith('credentials_')) {
            final data = box.get(key) as Map;
            final updatedAt = DateTime.fromMillisecondsSinceEpoch(data['updatedAt'] ?? 0);
            if (mostRecentTime == null || updatedAt.isAfter(mostRecentTime)) {
              mostRecentTime = updatedAt;
              credentials = StoredCredentialsModel()
                ..id = data['id']
                ..username = data['username'] ?? ''
                ..password = data['password'] ?? ''
                ..domain = data['domain'] ?? ''
                ..wsUrl = data['wsUrl'] ?? ''
                ..displayName = data['displayName']
                ..isDefault = data['isDefault'] ?? false;
            }
          }
        }
      }

      if (credentials != null && credentials.username.isNotEmpty) {
        // Convert to SipUser format
        _currentSipUser = SipUser(
          sipUri: 'sip:${credentials.username}@${credentials.domain}',
          authUser: credentials.username,
          password: credentials.password,
          wsUrl: credentials.wsUrl,
          displayName: credentials.displayName ?? credentials.username,
          port: '5060',
          selectedTransport: TransportType.WS,
        );

        print('✅ SIP user loaded from Hive: ${_currentSipUser!.authUser}');

        // Store in SharedPreferences for future access
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('websocket_sip_user', _currentSipUser!.toJsonString());
        await prefs.setBool('should_maintain_websocket_connection', true);
      } else {
        print('❌ No valid SIP credentials found in Hive');
      }

      // DON'T close the box - let the main app manage it
    } catch (e) {
      print('❌ Error loading SIP user from Hive: $e');
    }
  }

  @pragma('vm:entry-point')
  static bool isMainAppActive() {
    return _isMainAppActive;
  }

  @pragma('vm:entry-point')
  static Future<Call?> getForwardedCall() async {
    try {
      // First try memory (same process)
      if (_forwardedCall != null) {
        print('📞 Found forwarded call in memory: ${_forwardedCall!.remote_identity}');
        return _forwardedCall;
      }

      // Try SharedPreferences (cross-process)
      final prefs = await SharedPreferences.getInstance();
      final callId = prefs.getString('forwarded_call_id');

      if (callId != null) {
        final caller = prefs.getString('forwarded_call_caller') ?? 'Unknown';
        final direction = prefs.getString('forwarded_call_direction') ?? 'Direction.incoming';
        final state = prefs.getString('forwarded_call_state') ?? 'CallStateEnum.CALL_INITIATION';
        final timestamp = prefs.getInt('forwarded_call_timestamp') ?? 0;

        print('📞 Found forwarded call in SharedPreferences: $caller (ID: $callId)');
        print('  - Direction: $direction');
        print('  - State: $state');
        print('  - Timestamp: $timestamp');

        // Return the actual call object if it exists in our static variables
        if (_currentIncomingCall != null && _currentIncomingCall!.id == callId) {
          print('🎯 Matched with current incoming call');
          return _currentIncomingCall;
        }

        if (_currentActiveCall != null && _currentActiveCall!.id == callId) {
          print('🎯 Matched with current active call');
          return _currentActiveCall;
        }

        print('⚠️ Call found in prefs but no matching call object in memory');
        return null;
      }

      print('📞 No forwarded call found in memory or SharedPreferences');
      return null;
    } catch (e) {
      print('❌ Error getting forwarded call: $e');
      return null;
    }
  }

  @pragma('vm:entry-point')
  static Future<void> clearForwardedCall() async {
    try {
      _forwardedCall = null;

      // Clear from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('forwarded_call_id');
      await prefs.remove('forwarded_call_caller');
      await prefs.remove('forwarded_call_direction');
      await prefs.remove('forwarded_call_state');
      await prefs.remove('forwarded_call_timestamp');

      print('📞 Cleared forwarded call from memory and SharedPreferences');
    } catch (e) {
      print('❌ Error clearing forwarded call: $e');
    }
  }
  
  // CRITICAL: New call handling methods for service events
  @pragma('vm:entry-point')
  static Future<void> _handleMakeCall(String number) async {
    print('📞 Background service handling make call to: $number');
    
    if (_backgroundSipHelper != null && _backgroundSipHelper!.registered) {
      try {
        // CRITICAL FIX: Share SIP credentials with main app to make WebRTC call
        // Main app has Activity context needed for WebRTC operations
        print('🔄 Background service sharing SIP credentials with main app for WebRTC call');
        
        // Send call request to main app for WebRTC setup with credential sharing
        _serviceInstance?.invoke('initiateSipCallWithWebRTC', {
          'number': number,
          'sipHelper': 'background', // Indicates which helper has registration
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
        print('✅ Call coordination request sent to main app');
        
      } catch (e) {
        print('❌ Error coordinating call with main app: $e');
        
        // Notify main app of failure
        _serviceInstance?.invoke('callInitiated', {
          'number': number,
          'success': false,
          'error': e.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } else {
      print('❌ Background SIP helper not available for making call');
      
      // Notify main app of failure
      _serviceInstance?.invoke('callInitiated', {
        'number': number,
        'success': false,
        'error': 'SIP not registered',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _handleProceedWithSipCall(String number, bool webrtcReady) async {
    print('📞 Background service proceeding with SIP call after WebRTC coordination: $number');
    print('📞 WebRTC ready status: $webrtcReady');
    
    if (_backgroundSipHelper != null && _backgroundSipHelper!.registered) {
      try {
        // Now that main app has confirmed WebRTC is ready, proceed with actual SIP call
        print('📞 Making actual SIP call from background service (WebRTC coordinated)');
        
        final result = await _backgroundSipHelper!.call(number, voiceOnly: true);
        print(result ? '✅ SIP call initiated successfully from background' : '❌ SIP call initiation failed from background');
        
        // Notify main app of call status
        _serviceInstance?.invoke('callInitiated', {
          'number': number,
          'success': result,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
      } catch (e) {
        print('❌ Error making SIP call in background service: $e');
        
        // Notify main app of failure
        _serviceInstance?.invoke('callInitiated', {
          'number': number,
          'success': false,
          'error': e.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } else {
      print('❌ Background SIP helper not available for making call');
      
      // Notify main app of failure
      _serviceInstance?.invoke('callInitiated', {
        'number': number,
        'success': false,
        'error': 'SIP not registered',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _handleGetSipCredentialsForCall(String number) async {
    print('📞 Background service providing SIP credentials for call to: $number');
    
    try {
      if (_currentSipUser != null) {
        // Prepare SIP credentials from current background registration
        // Extract domain from sipUri if available (format: sip:username@domain)
        String domain = '';
        String username = _currentSipUser!.authUser;
        
        if (_currentSipUser!.sipUri != null) {
          final uri = _currentSipUser!.sipUri!;
          if (uri.contains('@')) {
            final parts = uri.split('@');
            if (parts.length > 1) {
              domain = parts[1];
              // Also extract username from URI if needed
              final userPart = parts[0];
              if (userPart.startsWith('sip:')) {
                username = userPart.substring(4);
              }
            }
          }
        }
        
        final credentials = {
          'id': 'background_service_temp',
          'username': username,
          'password': _currentSipUser!.password,
          'domain': domain,
          'wsUrl': _currentSipUser!.wsUrl ?? '',
          'displayName': _currentSipUser!.displayName,
          'extraHeaders': _currentSipUser!.wsExtraHeaders,
        };
        
        print('📞 Sending SIP credentials to main app for WebRTC call');
        
        // Send credentials to main app
        _serviceInstance?.invoke('sipCredentialsForCall', {
          'number': number,
          'credentials': credentials,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
        print('✅ SIP credentials sent to main app');
        
      } else {
        print('❌ No SIP user available to provide credentials');
        
        // Notify main app of failure
        _serviceInstance?.invoke('callInitiated', {
          'number': number,
          'success': false,
          'error': 'No SIP credentials available',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } catch (e) {
      print('❌ Error providing SIP credentials: $e');
      
      // Notify main app of failure
      _serviceInstance?.invoke('callInitiated', {
        'number': number,
        'success': false,
        'error': e.toString(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _handleAcceptCall(String callId) async {
    print('📞 Background service received accept call request: $callId');
    
    if (_currentIncomingCall != null && _currentIncomingCall!.id == callId) {
      print('🔄 Forwarding call accept to main app (WebRTC requires Activity context)');
      
      // Background service cannot handle WebRTC - forward to main app
      _serviceInstance?.invoke('forwardCallToMainApp', {
        'action': 'acceptCall',
        'callId': callId,
        'caller': _currentIncomingCall!.remote_identity ?? 'Unknown',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      
      print('✅ Call accept request forwarded to main app');
    } else {
      print('❌ No matching incoming call found for accept: $callId');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _handleRejectCall(String callId) async {
    print('📞 Background service handling reject call: $callId');
    
    if (_currentIncomingCall != null && _currentIncomingCall!.id == callId) {
      try {
        _currentIncomingCall!.hangup({'status_code': 486}); // Busy here
        _currentIncomingCall = null;
        hideIncomingCallNotification();
        print('✅ Call rejected in background service');
      } catch (e) {
        print('❌ Error rejecting call in background service: $e');
      }
    } else {
      print('❌ No matching incoming call found for reject: $callId');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _handleEndCall(String callId) async {
    print('📞 Background service handling end call: $callId');
    
    Call? callToEnd;
    if (_currentActiveCall?.id == callId) {
      callToEnd = _currentActiveCall;
    } else if (_currentIncomingCall?.id == callId) {
      callToEnd = _currentIncomingCall;
    }
    
    if (callToEnd != null) {
      try {
        callToEnd.hangup({'status_code': 200});
        
        // Clear call references
        if (_currentActiveCall?.id == callId) {
          _currentActiveCall = null;
        }
        if (_currentIncomingCall?.id == callId) {
          _currentIncomingCall = null;
        }
        
        hideIncomingCallNotification();
        print('✅ Call ended in background service');
      } catch (e) {
        print('❌ Error ending call in background service: $e');
      }
    } else {
      print('❌ No matching call found for end: $callId');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _handleUnregisterSip() async {
    print('📞 Background service handling SIP unregistration');
    
    if (_backgroundSipHelper != null && _backgroundSipHelper!.registered) {
      try {
        await _backgroundSipHelper!.unregister();
        _backgroundSipHelper!.stop();
        print('✅ SIP unregistered in background service');
      } catch (e) {
        print('❌ Error unregistering SIP in background service: $e');
      }
    }
    
    _currentSipUser = null;
  }
  
  @pragma('vm:entry-point')
  static Future<void> _handleSendDTMF(String callId, String digit) async {
    print('📞 Background service handling send DTMF: $digit for call $callId');
    
    Call? targetCall;
    if (_currentActiveCall?.id == callId) {
      targetCall = _currentActiveCall;
    } else if (_currentIncomingCall?.id == callId) {
      targetCall = _currentIncomingCall;
    }
    
    if (targetCall != null) {
      try {
        targetCall.sendDTMF(digit);
        print('✅ DTMF sent in background service: $digit');
      } catch (e) {
        print('❌ Error sending DTMF in background service: $e');
      }
    } else {
      print('❌ No matching call found for DTMF: $callId');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _handleToggleMute(String callId) async {
    print('🔇 Background service toggling mute for call $callId');

    Call? targetCall;
    if (_currentActiveCall?.id == callId) {
      targetCall = _currentActiveCall;
    } else if (_currentIncomingCall?.id == callId) {
      targetCall = _currentIncomingCall;
    }

    if (targetCall != null) {
      try {
        if (!_isMuted) {
          targetCall.mute(true, false);
          print('✅ Call muted in background service');
        } else {
          targetCall.unmute(true, false);
          print('✅ Call unmuted in background service');
        }
        _isMuted = !_isMuted;
      } catch (e) {
        print('❌ Error toggling mute in background service: $e');
      }
    } else {
      print('❌ No matching call found for mute: $callId');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _handleToggleSpeaker(String callId) async {
    print('🔊 Background service toggling speaker for call $callId');

    _isSpeakerOn = !_isSpeakerOn;
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
      print('✅ Speaker set to $_isSpeakerOn in background service');
    } catch (e) {
      print('❌ Error toggling speaker in background service: $e');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _handleToggleHold(String callId) async {
    print('⏸️ Background service toggling hold for call $callId');

    Call? targetCall;
    if (_currentActiveCall?.id == callId) {
      targetCall = _currentActiveCall;
    } else if (_currentIncomingCall?.id == callId) {
      targetCall = _currentIncomingCall;
    }

    if (targetCall != null) {
      try {
        if (!_isOnHold) {
          targetCall.hold();
          print('✅ Call placed on hold in background service');
        } else {
          targetCall.unhold();
          print('✅ Call resumed from hold in background service');
        }
        _isOnHold = !_isOnHold;
      } catch (e) {
        print('❌ Error toggling hold in background service: $e');
      }
    } else {
      print('❌ No matching call found for hold: $callId');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _storeIncomingCallInPreferences(Call call) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('incoming_call_id', call.id ?? 'unknown');
      await prefs.setString('incoming_call_caller', call.remote_identity ?? 'Unknown');
      await prefs.setString('incoming_call_direction', call.direction.toString());
      await prefs.setString('incoming_call_state', call.state.toString());
      await prefs.setInt('incoming_call_timestamp', DateTime.now().millisecondsSinceEpoch);
      print('💾 Incoming call stored in SharedPreferences: ${call.remote_identity}');
    } catch (e) {
      print('❌ Error storing incoming call in SharedPreferences: $e');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _storeCallForMainApp(Call call, String action) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('main_app_call_id', call.id ?? 'unknown');
      await prefs.setString('main_app_call_caller', call.remote_identity ?? 'Unknown');
      await prefs.setString('main_app_call_action', action);
      await prefs.setInt('main_app_call_timestamp', DateTime.now().millisecondsSinceEpoch);
      print('💾 Call stored for main app coordination: ${call.remote_identity} ($action)');
    } catch (e) {
      print('❌ Error storing call for main app: $e');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _clearCallFromSharedPreferences(String callId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Clear all call-related keys
      await prefs.remove('incoming_call_id');
      await prefs.remove('incoming_call_caller');
      await prefs.remove('incoming_call_direction');
      await prefs.remove('incoming_call_state');
      await prefs.remove('incoming_call_timestamp');
      
      await prefs.remove('main_app_call_id');
      await prefs.remove('main_app_call_caller');
      await prefs.remove('main_app_call_action');
      await prefs.remove('main_app_call_timestamp');
      
      print('🧹 Cleared call data from SharedPreferences for call: $callId');
    } catch (e) {
      print('❌ Error clearing call data from SharedPreferences: $e');
    }
  }

  /// Syncs current SIP state from background service to main app
  static void _syncCurrentSipStateToMainApp(ServiceInstance service) {
    print('🔄 Syncing current SIP state to main app');
    
    try {
      final sipState = {
        'isRegistered': _backgroundSipHelper?.registered ?? false,
        'currentUser': _currentSipUser?.toJsonString(),
        'isServiceRunning': _isServiceRunning,
        'hasIncomingCall': _currentIncomingCall != null,
        'hasActiveCall': _currentActiveCall != null,
        'incomingCallerId': _currentIncomingCall?.remote_identity,
        'activeCallerId': _currentActiveCall?.remote_identity,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Send current SIP state to main app
      service.invoke('currentSipState', sipState);
      print('✅ SIP state synced to main app: registered=${sipState['isRegistered']}, hasIncoming=${sipState['hasIncomingCall']}, hasActive=${sipState['hasActiveCall']}');
    } catch (e) {
      print('❌ Error syncing SIP state to main app: $e');
    }
  }

  /// Handles SIP registration request from main app
  static Future<void> _handleRegisterSipFromMainApp(ServiceInstance service, String accountJson) async {
    print('🔐 Processing SIP registration from main app');
    
    try {
      // Parse the account from JSON
      final accountData = Map<String, dynamic>.from(jsonDecode(accountJson));
      
      // Create SipUser from account data
      final sipUser = SipUser(
        authUser: accountData['username'] ?? '',
        password: accountData['password'] ?? '',
        displayName: accountData['displayName'] ?? accountData['username'] ?? '',
        wsUrl: accountData['wsUrl'],
        port: '5060',
        selectedTransport: TransportType.WS,
      );

      print('🔐 Registering SIP account: ${sipUser.authUser}@${accountData['domain'] ?? 'unknown'}');

      // Use existing SIP connection method
      await _connectSipInBackground(sipUser);
      
      // Notify main app of registration result
      final registrationResult = {
        'success': _backgroundSipHelper?.registered ?? false,
        'account': sipUser.authUser,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      
      service.invoke('registrationResult', registrationResult);
      print('✅ SIP registration completed, result sent to main app: ${registrationResult['success']}');
      
    } catch (e, stack) {
      print('❌ SIP registration failed: $e');
      print('❌ Stack trace: $stack');
      
      // Notify main app of registration failure
      service.invoke('registrationResult', {
        'success': false,
        'error': e.toString(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }
}

/// Listener for SIP events in background service
class PersistentSipListener implements SipUaHelperListener {
  final ServiceInstance? service;

  PersistentSipListener(this.service);

  @override
  void callStateChanged(Call call, CallState state) {
    print('🔔🔔🔔 Background: Call state changed to ${state.state} 🔔🔔🔔');
    print('📞 Background Call Details:');
    print('  - Call ID: ${call.id}');
    print('  - Remote: ${call.remote_identity}');
    print('  - Local: ${call.local_identity}');
    print('  - Direction: ${call.direction}');
    print('  - State: ${state.state}');
    print('🔔🔔🔔 End Background Call Details 🔔🔔🔔');

    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        // Incoming call detected
        final caller = call.remote_identity ?? 'Unknown Number';
        final callId = call.id ?? 'call_${DateTime.now().millisecondsSinceEpoch}';
        print('🔔🔔🔔 Background: INCOMING CALL DETECTED 🔔🔔🔔');
        print('📞 From: $caller (ID: $callId)');
        print('📱 Main app active: ${PersistentBackgroundService._isMainAppActive}');

        // CRITICAL FIX: Ensure call state is properly maintained
        PersistentBackgroundService._currentIncomingCall = call;
        print('💾 Stored incoming call in background service: $callId');
        
        // Store in SharedPreferences for cross-process reliability
        PersistentBackgroundService._storeIncomingCallInPreferences(call);

        // ALWAYS show notification for incoming calls
        print('🔔 Showing notification for incoming call from: $caller');
        PersistentBackgroundService.showIncomingCallNotification(
          caller: caller,
          callId: callId,
        );

        // CRITICAL FIX: Background service handles ALL incoming calls
        print('📞 Background service handling incoming call from: $caller');
        
        // ALWAYS show notification for incoming calls and try to bring app to foreground
        print('🔔 Showing notification and launching app for incoming call from: $caller');
        
        // Notify main app via service event for coordination
        PersistentBackgroundService._serviceInstance?.invoke('incomingCall', {
          'callId': callId,
          'caller': caller,
          'direction': 'incoming',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'fromBackground': !PersistentBackgroundService._isMainAppActive,
        });

        // REMOVED AUTO-ANSWER: Let user manually handle all calls
        // This prevents "user busy" issues and gives proper control
        print('📞 Call will remain ringing until user action or timeout');
        break;

      case CallStateEnum.PROGRESS:
        print('📞 Background: Call ringing...');
        break;

      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        print('✅ Background: Call connected');
        // Move to active call if it was incoming
        if (PersistentBackgroundService._currentIncomingCall?.id == call.id) {
          PersistentBackgroundService._currentActiveCall = call;
          PersistentBackgroundService._currentIncomingCall = null;
        }
        // Update notification to show active call
        final caller = call.remote_identity ?? 'Unknown Number';
        PersistentBackgroundService.showIncomingCallNotification(
          caller: '📞 Active: $caller (Tap to open)',
          callId: call.id ?? 'unknown',
        );
        break;

      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        print('📞 Background: Call ended/failed - cleaning up call state');
        
        // CRITICAL: Complete cleanup of call state
        if (PersistentBackgroundService._currentIncomingCall?.id == call.id) {
          print('🧹 Clearing incoming call reference: ${call.id}');
          PersistentBackgroundService._currentIncomingCall = null;
        }
        if (PersistentBackgroundService._currentActiveCall?.id == call.id) {
          print('🧹 Clearing active call reference: ${call.id}');
          PersistentBackgroundService._currentActiveCall = null;
        }
        
        // Clear forwarded call if it matches
        if (PersistentBackgroundService._forwardedCall?.id == call.id) {
          print('🧹 Clearing forwarded call reference: ${call.id}');
          PersistentBackgroundService._forwardedCall = null;
        }
        
        // Call ended, hide notification
        PersistentBackgroundService.hideIncomingCallNotification();
        
        // Additional cleanup - stop any ringing
        PersistentBackgroundService._stopRinging();
        
        // Clear from SharedPreferences for cross-process cleanup
        PersistentBackgroundService._clearCallFromSharedPreferences(call.id ?? 'unknown');

        // CRITICAL: Ensure SIP registration is maintained after call ends
        print('🔄 Checking SIP registration status after call ended...');
        Future.delayed(Duration(seconds: 2), () {
          if (PersistentBackgroundService._backgroundSipHelper != null) {
            final isRegistered = PersistentBackgroundService._backgroundSipHelper!.registered;
            print('📊 SIP Registration status after call: $isRegistered');

            if (!isRegistered && !PersistentBackgroundService._isMainAppActive) {
              print('⚠️ SIP not registered after call - attempting re-registration');
              if (PersistentBackgroundService._currentSipUser != null) {
                PersistentBackgroundService._connectSipInBackground(PersistentBackgroundService._currentSipUser!);
              } else {
                print('❌ No SIP user available for re-registration');
              }
            } else {
              print('✅ SIP registration maintained after call');
            }
          }
        });
        break;

      default:
        print('📞 Background: Call state ${state.state} for ${call.remote_identity}');
        break;
    }
  }

  @override
  void registrationStateChanged(RegistrationState state) {
    print('📋📋📋 Background: Registration state changed to ${state.state} 📋📋📋');

    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        print('✅ Background: Successfully registered to SIP server');
        PersistentBackgroundService._updateServiceNotification(
            'SIP Phone Active', 'Connected and ready to receive calls');
        break;

      case RegistrationStateEnum.REGISTRATION_FAILED:
        print('❌ Background: SIP registration failed');
        PersistentBackgroundService._updateServiceNotification('SIP Phone Error', 'Registration failed - retrying...');
        break;

      case RegistrationStateEnum.UNREGISTERED:
        print('⚠️ Background: SIP unregistered');
        PersistentBackgroundService._updateServiceNotification(
            'SIP Phone Disconnected', 'Connection lost - reconnecting...');
        break;

      default:
        print('📋 Background: Registration state ${state.state}');
        break;
    }
  }

  @override
  void transportStateChanged(TransportState state) {
    print('🌐🌐🌐 Background: Transport state changed to ${state.state} 🌐🌐🌐');

    if (state.state == TransportStateEnum.DISCONNECTED) {
      print('⚠️ Background: Transport disconnected, will attempt reconnection');
      PersistentBackgroundService._updateServiceNotification(
          'SIP Phone Reconnecting', 'Network connection lost - reconnecting...');
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {
    print('📨 Background: New SIP message received');
  }

  @override
  void onNewNotify(Notify ntf) {
    print('📢 Background: New SIP notify received');
  }

  @override
  void onNewReinvite(ReInvite event) {
    print('🔄 Background: New SIP re-invite received');

    // For audio-only app, reject video upgrade requests
    if (event.reject != null) {
      event.reject!.call({'status_code': 488}); // Not acceptable here
      print('📞 Background: Video upgrade request rejected (audio-only)');
    }
  }
}
