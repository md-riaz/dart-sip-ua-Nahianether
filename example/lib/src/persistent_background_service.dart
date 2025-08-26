import 'dart:async';
import 'dart:ui';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_state/sip_user.dart';

/// Persistent background service that maintains SIP connection
/// and handles incoming calls even when app is closed/locked
@pragma('vm:entry-point')
class PersistentBackgroundService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  
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

  @pragma('vm:entry-point')
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Initialize notifications first
    await _initializeNotifications();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
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
    await service.startService();
    _isServiceRunning = await service.isRunning();

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

    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true, // For critical incoming call alerts
    );

    const InitializationSettings initializationSettings =
        InitializationSettings(
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
    print('📱 Notification tapped: ${response.payload}');
    
    // Handle notification actions
    if (response.actionId == 'answer_call') {
      print('✅ Answer call action tapped');
      _handleAcceptCallFromNotification(response.payload);
    } else if (response.actionId == 'decline_call') {
      print('❌ Decline call action tapped');
      _handleDeclineCallFromNotification(response.payload);
    } else if (response.payload?.contains('incoming_call') == true) {
      print('🔔 Incoming call notification tapped - opening app');
      _launchAppWithIncomingCall(response.payload);
    }
  }

  @pragma('vm:entry-point')
  static void _handleAcceptCallFromNotification(String? payload) {
    print('📞 Accepting call from notification');
    
    if (_currentIncomingCall != null) {
      try {
        // Accept with audio-only constraints
        final mediaConstraints = <String, dynamic>{
          'audio': true,
          'video': false,
        };
        _currentIncomingCall!.answer(mediaConstraints);
        print('✅ Call accepted from notification');
        
        // Move to active call
        _currentActiveCall = _currentIncomingCall;
        _currentIncomingCall = null;
        
        // Open the app to show call screen
        _launchAppWithIncomingCall(payload);
      } catch (e) {
        print('❌ Error accepting call from notification: $e');
      }
    }
  }

  @pragma('vm:entry-point')
  static void _handleDeclineCallFromNotification(String? payload) {
    print('📞 Declining call from notification');
    
    if (_currentIncomingCall != null) {
      try {
        _currentIncomingCall!.hangup({'status_code': 486}); // Busy here
        print('✅ Call declined from notification');
        _currentIncomingCall = null;
        hideIncomingCallNotification();
      } catch (e) {
        print('❌ Error declining call from notification: $e');
      }
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
    
    print('📱 iOS background service activated');
    return true;
  }

  @pragma('vm:entry-point')  
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    
    if (_isServiceRunning) {
      print('⚠️ Service already running, ignoring duplicate start');
      return;
    }
    
    _serviceInstance = service;
    _isServiceRunning = true;
    print('🚀 Persistent background service started');
    print('📱 Main app active status on service start: $_isMainAppActive');
    
    // Load and start SIP connection
    await _initializePersistentSipConnection(service);
    
    // Set up service control listeners
    service.on('stopService').listen((event) {
      _stopPersistentService();
      service.stopSelf();
    });
    
    service.on('updateSipUser').listen((event) async {
      final data = event!['sipUser'] as String;
      final sipUser = SipUser.fromJsonString(data);
      await _updateSipConnection(sipUser);
    });
    
    service.on('forwardCallToMainApp').listen((event) {
      print('🔄 Background service received forward call to main app request');
      final data = event as Map<String, dynamic>;
      final caller = data['caller'] as String;
      final callId = data['callId'] as String;
      
      // This will be handled by the main app - just log for now
      print('📞 Call forwarded to main app: $caller (ID: $callId)');
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
    
    // Update service notification status
    _updateServiceNotification('SIP Phone Ready', 'Connected and ready to receive calls');
  }

  @pragma('vm:entry-point')
  static Future<void> _initializePersistentSipConnection(ServiceInstance service) async {
    try {
      print('🔄 Initializing persistent SIP connection in background...');
      
      // Load SIP user configuration
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');
      final shouldMaintain = prefs.getBool('should_maintain_websocket_connection') ?? false;
      
      if (savedUserJson == null || !shouldMaintain) {
        print('⚠️ No saved SIP user configuration found');
        _updateServiceNotification('SIP Phone', 'Not configured');
        return;
      }
      
      _currentSipUser = SipUser.fromJsonString(savedUserJson);
      print('📋 Loaded SIP user: ${_currentSipUser!.authUser}');
      
      // Initialize SIP helper
      _backgroundSipHelper = SIPUAHelper();
      final listener = PersistentSipListener(service);
      _backgroundSipHelper!.addSipUaHelperListener(listener);
      print('✅ Background SIP helper initialized');
      
      // Check if main app is active - simplified logic
      final mainAppActive = prefs.getBool('main_app_is_active') ?? false;
      print('📊 Main app active status: $mainAppActive');
      
      if (mainAppActive) {
        print('📱 Main app is active - background service in standby mode');
        _isMainAppActive = true;
        _updateServiceNotification(
          'SIP Phone (Standby)', 
          'Main app active - background service ready'
        );
      } else {
        print('🔄 Main app is background - starting SIP connection');
        _isMainAppActive = false;
        await _connectSipInBackground(_currentSipUser!);
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
      
      if (_backgroundSipHelper == null) {
        print('❌ SIP helper not initialized - creating new one');
        _backgroundSipHelper = SIPUAHelper();
        
        // Add listener if service instance is available
        if (_serviceInstance != null) {
          final listener = PersistentSipListener(_serviceInstance!);
          _backgroundSipHelper!.addSipUaHelperListener(listener);
          print('✅ Background SIP listener added during connection');
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
      
      // Final check before connecting
      if (_isMainAppActive && !allowBackupConnection) {
        print('⚠️ Main app became active during connection - aborting');
        return;
      }
      
      if (_isMainAppActive && allowBackupConnection) {
        print('📞 Proceeding with backup connection while main app is active');
      }
      
      await _backgroundSipHelper!.start(settings);
      print('✅ Background SIP connection started');
      
      // Wait a moment for registration to complete
      await Future.delayed(Duration(seconds: 2));
      
      if (_backgroundSipHelper!.registered) {
        print('✅✅ Background SIP successfully registered! ✅✅');
        _updateServiceNotification('SIP Phone Active (Background)', 
            'Connected and ready to receive calls in background');
      } else {
        print('❌ Background SIP registration failed - will retry');
        throw Exception('Background SIP registration failed');
      }
      
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
      // Check if main app is active
      if (_isMainAppActive) {
        print('📱 Keep-alive: Main app active - background in standby');
        
        if (_backgroundSipHelper?.registered == true) {
          print('📴 Unregistering background SIP while main app active');
          await _backgroundSipHelper!.unregister();
        }
        
        _updateServiceNotification(
          'SIP Phone (Standby)', 
          'Main app active - background service ready'
        );
        return;
      }
      
      if (_backgroundSipHelper?.registered == true) {
        print('💓 Background SIP keep-alive check: Connected');
        print('📊 Background SIP Helper Status:');
        print('  - Registered: ${_backgroundSipHelper?.registered}');
        print('  - WebSocket URL: ${_currentSipUser?.wsUrl}');
        print('  - Background helper ready: ${_backgroundSipHelper != null}');
        print('  - Service running: $_isServiceRunning');
        _updateServiceNotification('SIP Phone 24/7 Active', 
            'Background service ready • ${DateTime.now().toString().substring(11, 16)}');
      } else {
        print('⚠️ Background SIP keep-alive check: Disconnected');
        _updateServiceNotification('SIP Phone Reconnecting', 'Attempting to reconnect...');
        if (_currentSipUser != null) {
          _connectSipInBackground(_currentSipUser!);
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
          print('📱 Health check: Main app active - background in standby');
          if (_backgroundSipHelper?.registered == true) {
            await _backgroundSipHelper!.unregister();
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
    // Update service notification via service instance
    _serviceInstance?.invoke('updateNotification', {
      'title': title,
      'content': content,
    });
  }

  @pragma('vm:entry-point')
  static Future<void> showIncomingCallNotification({
    required String caller,
    required String callId,
  }) async {
    print('🔔 Checking if notification should be shown for: $caller');
    
    // CRITICAL: Check if main app is active - if so, NO NOTIFICATION needed!
    try {
      final prefs = await SharedPreferences.getInstance();
      final mainAppActive = prefs.getBool('main_app_is_active') ?? false;
      
      if (mainAppActive) {
        print('🚫 MAIN APP ACTIVE: Skipping notification - main app will handle call directly');
        print('📱 Main app should already be showing incoming call screen');
        return; // Exit early - no notification needed
      }
      
      print('📱 MAIN APP INACTIVE: Proceeding with notification and auto-launch');
    } catch (e) {
      print('⚠️ Could not check main app status: $e - proceeding with notification');
    }
    
    print('🔔 Showing incoming call notification for: $caller');
    
    // 🔥🔥 ZERO-TOUCH AUTO-LAUNCH - APP COMES TO FOREGROUND AUTOMATICALLY 🔥🔥
    print('🚀🚀🚀 AUTOMATIC FOREGROUND LAUNCH for incoming call from: $caller (NO USER INTERACTION REQUIRED)');
    
    // IMMEDIATE LAUNCH: Attempt 1 - Direct auto-launch without notification dependency
    try {
      const platform = MethodChannel('sip_phone/incoming_call');
      await platform.invokeMethod('forceOpenAppForCall', {
        'caller': caller,
        'callId': callId,
        'autoLaunch': true,
        'automaticForeground': true,
        'noUserInteraction': true,
      });
      print('🎉 ZERO-TOUCH: App auto-launched to foreground successfully (attempt 1)');
    } catch (e) {
      print('⚠️ Auto-launch attempt 1 failed: $e');
    }
    
    // AGGRESSIVE RETRY: Attempt 2 - More aggressive after short delay
    Timer(Duration(milliseconds: 200), () async {
      try {
        const platform = MethodChannel('sip_phone/incoming_call');
        await platform.invokeMethod('forceOpenAppForCall', {
          'caller': caller,
          'callId': callId,
          'autoLaunch': true,
          'automaticForeground': true,
          'noUserInteraction': true,
          'aggressive': true,
          'retry': 2,
        });
        print('🎉 ZERO-TOUCH: App auto-launched to foreground successfully (attempt 2 - aggressive)');
      } catch (e) {
        print('⚠️ Auto-launch attempt 2 failed: $e');
      }
    });
    
    // SUPER AGGRESSIVE: Attempt 3 - Maximum force after longer delay
    Timer(Duration(milliseconds: 500), () async {
      try {
        const platform = MethodChannel('sip_phone/incoming_call');
        await platform.invokeMethod('forceOpenAppForCall', {
          'caller': caller,
          'callId': callId,
          'autoLaunch': true,
          'automaticForeground': true,
          'noUserInteraction': true,
          'superAggressive': true,
          'retry': 3,
        });
        print('🎉 ZERO-TOUCH: App auto-launched to foreground successfully (attempt 3 - SUPER AGGRESSIVE)');
      } catch (e) {
        print('⚠️ Auto-launch attempt 3 failed: $e');
      }
    });
    
    // NUCLEAR OPTION: Attempt 4 - Last resort with maximum delay
    Timer(Duration(seconds: 1), () async {
      try {
        const platform = MethodChannel('sip_phone/incoming_call');
        await platform.invokeMethod('forceOpenAppForCall', {
          'caller': caller,
          'callId': callId,
          'autoLaunch': true,
          'automaticForeground': true,
          'noUserInteraction': true,
          'nuclearOption': true,
          'retry': 4,
        });
        print('🎉 ZERO-TOUCH: App auto-launched to foreground successfully (attempt 4 - NUCLEAR)');
      } catch (e) {
        print('⚠️ Auto-launch attempt 4 failed: $e');
      }
    });
    
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
      actions: [
        AndroidNotificationAction(
          'answer_call',
          '📞 ANSWER',
          titleColor: Color.fromARGB(255, 0, 255, 0),
          icon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          contextual: true,
        ),
        AndroidNotificationAction(
          'decline_call', 
          '❌ DECLINE',
          titleColor: Color.fromARGB(255, 255, 0, 0),
          icon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          contextual: true,
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

    await _notificationsPlugin.show(
      999, // Fixed ID for incoming calls
      '📞 INCOMING CALL - TAP TO ANSWER',
      '🔥 URGENT: Call from $caller - Tap anywhere to open app and answer',
      notificationDetails,
      payload: 'incoming_call:$callId:$caller',
    );
    
    print('✅ Incoming call notification displayed');
    
    // Also try the original method as backup
    try {
      // Use MethodChannel to attempt to launch the app
      const platform = MethodChannel('sip_phone/incoming_call');
      await platform.invokeMethod('launchIncomingCallScreen', {
        'caller': caller,
        'callId': callId,
        'fromBackground': true,
      });
      print('📱 Platform channel call made to launch app');
    } catch (e) {
      print('⚠️ Could not call platform channel: $e');
      // This is expected in background service - notifications will handle app launch
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
    final service = FlutterBackgroundService();
    service.invoke('updateSipUser', {
      'sipUser': sipUser.toJsonString(),
    });
    print('🔄 SIP user update sent to background service');
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
    print('📱 Main app status: ${isActive ? "ACTIVE" : "BACKGROUND"}');
    _isMainAppActive = isActive;
    
    // Save to SharedPreferences asynchronously
    _handleMainAppStatusChange(isActive);
    
    if (isActive) {
      print('📱 Main app active - unregistering background service');
      _temporarilyUnregisterForMainApp();
    } else {
      print('🔄 Main app backgrounded - re-registering background SIP');
      _reregisterAfterMainAppBackground();
    }
  }
  
  @pragma('vm:entry-point')
  static void _handleMainAppStatusChange(bool isActive) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('main_app_is_active', isActive);
      _isMainAppActive = isActive;
      print('💾 Main app status updated: $isActive');
    } catch (e) {
      print('❌ Error saving main app status: $e');
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
          'SIP Phone (Main App Active)', 
          'Main app handling calls - background service standby'
        );
        
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
    
    if (_currentSipUser != null && !_isMainAppActive) {
      print('🚀 Starting background SIP connection');
      _connectSipInBackground(_currentSipUser!);
    } else {
      print('⚠️ Cannot re-register: user=${_currentSipUser != null}, mainAppActive=$_isMainAppActive');
    }
  }
  
  @pragma('vm:entry-point')
  static void _handleAndroidBackgroundRegistration() {
    print('🤖 ANDROID: Starting background SIP registration');
    
    if (_isMainAppActive) {
      print('⚠️ ANDROID: Main app still active - aborting');
      return;
    }
    
    if (_currentSipUser == null) {
      print('❌ ANDROID: No SIP user configuration');
      _loadSipUserFromPreferences();
      return;
    }
    
    print('🚀 ANDROID: Performing background registration');
    _performAndroidBackgroundRegistration();
  }
  
  @pragma('vm:entry-point')
  static void _performAndroidBackgroundRegistration() async {
    try {
      print('🤖 ANDROID: Performing background registration');
      
      if (_isMainAppActive) {
        print('⚠️ ANDROID: Main app became active - aborting');
        return;
      }
      
      if (_backgroundSipHelper == null) {
        _backgroundSipHelper = SIPUAHelper();
        if (_serviceInstance != null) {
          final listener = PersistentSipListener(_serviceInstance!);
          _backgroundSipHelper!.addSipUaHelperListener(listener);
        }
      }
      
      await Future.delayed(Duration(seconds: 2));
      
      if (_isMainAppActive) {
        print('⚠️ ANDROID: Main app active during wait - aborting');
        return;
      }
      
      await _connectSipInBackground(_currentSipUser!);
      
      _updateServiceNotification(
        'SIP Phone (Background)', 
        'Connected - ready for calls'
      );
      
      print('✅ ANDROID: Background registration completed');
      
    } catch (e) {
      print('❌ ANDROID: Registration failed: $e');
      
      Timer(Duration(seconds: 10), () {
        if (!_isMainAppActive && _currentSipUser != null) {
          _performAndroidBackgroundRegistration();
        }
      });
    }
  }
  
  @pragma('vm:entry-point')
  static void _startAndroidKeepAlive() {
    print('💗 ANDROID: Starting keep-alive mechanism for 24/7 operation');
    
    // More frequent keep-alive for better reliability in background
    Timer.periodic(Duration(seconds: 20), (timer) {
      if (_isMainAppActive) {
        print('📱 ANDROID: Main app active - pausing keep-alive');
        return;
      }
      
      if (_backgroundSipHelper == null || !_backgroundSipHelper!.registered) {
        print('⚠️ ANDROID: SIP connection lost - attempting reconnection');
        
        if (_currentSipUser != null) {
          _performAndroidBackgroundRegistration();
        }
      } else {
        print('💚 ANDROID: Background SIP healthy - keeping alive');
        
        // Update notification to show active status
        _updateServiceNotification(
          'SIP Phone (24/7 Active)', 
          'Connected to ${_currentSipUser?.authUser ?? "SIP"} - receiving calls'
        );
      }
    });
  }
  
  @pragma('vm:entry-point')
  static void _handleIOSVoIPCoordination() {
    print('🍎 iOS: Configuring VoIP coordination mode');
    print('📊 iOS: Background helper status: ${_backgroundSipHelper != null}');
    print('📊 iOS: Current SIP user: ${_currentSipUser != null}');
    print('📊 iOS: Service running: $_isServiceRunning');
    
    // iOS approach: Don't compete with main app, coordinate VoIP
    print('📱 iOS VoIP: Background service acts as notification coordinator only');
    
    // Ensure we have configuration for coordination
    if (_currentSipUser == null) {
      print('📋 iOS: Loading SIP configuration for coordination...');
      _loadSipUserFromPreferences();
    }
    
    // Update notification for iOS coordination mode
    _updateServiceNotification(
      'SIP Phone (iOS VoIP Ready)', 
      'Coordinating with iOS system for background calls'
    );
    
    print('✅ iOS: VoIP coordination configured');
  }
  
  @pragma('vm:entry-point')
  static void _attemptServiceRecovery() async {
    try {
      print('🚪🚪🚪 RECOVERY: Attempting to recover background service... 🚪🚪🚪');
      
      // Check platform and use appropriate recovery approach
      if (Platform.isIOS) {
        print('🍎 RECOVERY: iOS detected - using immediate registration approach');
        print('🍎 RECOVERY: iOS background limitations - starting direct SIP in main isolate');
        _startImmediateIOSRegistration();
      } else if (Platform.isAndroid) {
        print('🤖 RECOVERY: Android detected - using background service restart');
        _forceServiceRestart();
      } else {
        print('❓ RECOVERY: Unknown platform - using force restart');
        _forceServiceRestart();
      }
      
    } catch (e) {
      print('❌ Error during service recovery: $e');
      _forceServiceRestart();
    }
  }
  
  @pragma('vm:entry-point')
  static void _startImmediateIOSRegistration() async {
    print('🍎⚡ iOS IMMEDIATE: Starting immediate SIP registration in main isolate ⚡🍎');
    
    try {
      // Load SIP configuration immediately
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');
      
      if (savedUserJson == null) {
        print('❌ iOS IMMEDIATE: No SIP configuration found');
        return;
      }
      
      final sipUser = SipUser.fromJsonString(savedUserJson);
      _currentSipUser = sipUser;
      print('📋 iOS IMMEDIATE: Loaded SIP user: ${sipUser.authUser}');
      
      // Create minimal SIP helper immediately
      print('🔄 iOS IMMEDIATE: Creating minimal SIP helper for immediate registration...');
      _backgroundSipHelper = SIPUAHelper();
      
      // Add simple listener
      final listener = IOSFallbackSipListener();
      _backgroundSipHelper!.addSipUaHelperListener(listener);
      
      // Force service running flag
      _isServiceRunning = true;
      _isMainAppActive = false;
      
      print('🚀 iOS IMMEDIATE: Starting immediate SIP connection...');
      
      // Use minimal settings for maximum compatibility
      UaSettings settings = UaSettings();
      settings.webSocketUrl = sipUser.wsUrl!;
      settings.uri = sipUser.sipUri ?? 'sip:${sipUser.authUser}@sip.ibos.io';
      settings.authorizationUser = sipUser.authUser;
      settings.password = sipUser.password;
      settings.displayName = sipUser.displayName;
      settings.transportType = TransportType.WS;
      
      print('📝 iOS IMMEDIATE: Settings: WebSocket=${settings.webSocketUrl}, URI=${settings.uri}');
      
      // Start and register immediately
      print('🔥 iOS IMMEDIATE: Starting SIP helper...');
      _backgroundSipHelper!.start(settings);
      
      // Short delay then register
      await Future.delayed(Duration(seconds: 1));
      
      print('🔥 iOS IMMEDIATE: Registering with SIP server...');
      _backgroundSipHelper!.register();
      
      print('✅ iOS IMMEDIATE: Immediate registration process completed');
      
      // Check status after a moment
      Timer(Duration(seconds: 3), () {
        final registered = _backgroundSipHelper?.registered ?? false;
        print('📊 iOS IMMEDIATE: Registration status: $registered');
        
        if (registered) {
          print('🎉 iOS IMMEDIATE: Successfully registered with SIP server!');
          _updateServiceNotification(
            'SIP Phone (iOS Ready)', 
            'Ready to receive calls'
          );
        } else {
          print('⚠️ iOS IMMEDIATE: Registration may still be in progress...');
        }
      });
      
    } catch (e) {
      print('❌ iOS IMMEDIATE: Failed: $e');
    }
  }

  @pragma('vm:entry-point')
  static void _forceServiceRestart() async {
    try {
      print('🔥 Force restarting background service...');
      
      final service = FlutterBackgroundService();
      
      // Force stop and restart
      service.invoke('stopService');
      await Future.delayed(Duration(seconds: 1));
      
      await service.startService();
      await Future.delayed(Duration(seconds: 3));
      
      final isRunning = await service.isRunning();
      print('📊 Force restart result: $isRunning');
      
      if (isRunning) {
        print('✅ Force restart successful - retrying registration');
        Timer(Duration(seconds: 2), () {
          _reregisterAfterMainAppBackground();
        });
      } else {
        print('❌❌ Force restart failed - service cannot be recovered');
      }
      
    } catch (e) {
      print('❌ Error in force restart: $e');
    }
  }
  
  @pragma('vm:entry-point')
  static void _tryDirectSipRegistration() async {
    print('🍎🍎🍎 iOS FALLBACK: Starting direct SIP registration process 🍎🍎🍎');
    
    try {
      print('🔍 iOS FALLBACK: Step 1 - Loading SIP configuration from SharedPreferences...');
      
      // Load SIP user from preferences
      final prefs = await SharedPreferences.getInstance();
      print('📁 iOS FALLBACK: SharedPreferences instance obtained');
      
      final savedUserJson = prefs.getString('websocket_sip_user');
      print('📄 iOS FALLBACK: Raw saved user JSON: ${savedUserJson != null ? "Found (${savedUserJson.length} chars)" : "NULL"}');
      
      if (savedUserJson == null) {
        print('❌ iOS FALLBACK: No SIP user configuration found in SharedPreferences');
        print('❌ iOS FALLBACK: Cannot proceed without SIP configuration');
        return;
      }
      
      print('✅ iOS FALLBACK: Found SIP configuration in SharedPreferences');
      print('🔄 iOS FALLBACK: Step 2 - Parsing SIP user configuration...');
      
      final sipUser = SipUser.fromJsonString(savedUserJson);
      print('📋 iOS FALLBACK: Successfully parsed SIP user:');
      print('  - Auth User: ${sipUser.authUser}');
      print('  - Display Name: ${sipUser.displayName}');
      print('  - WebSocket URL: ${sipUser.wsUrl}');
      print('  - SIP URI: ${sipUser.sipUri}');
      
      // Set current user immediately
      _currentSipUser = sipUser;
      print('✅ iOS FALLBACK: SIP user stored in memory');
      
      print('🔄 iOS FALLBACK: Step 3 - Setting up SIP helper...');
      
      // Create a new SIP helper for direct registration
      if (_backgroundSipHelper == null) {
        print('🔗 iOS FALLBACK: Creating new SIP helper instance...');
        _backgroundSipHelper = SIPUAHelper();
        print('✅ iOS FALLBACK: SIP helper instance created (${_backgroundSipHelper.hashCode})');
        
        // For iOS fallback, create a simple listener
        print('🎧 iOS FALLBACK: Adding iOS-specific listener...');
        final listener = IOSFallbackSipListener();
        _backgroundSipHelper!.addSipUaHelperListener(listener);
        print('✅ iOS FALLBACK: iOS listener added to SIP helper');
      } else {
        print('✅ iOS FALLBACK: SIP helper already exists (${_backgroundSipHelper.hashCode})');
        print('📊 iOS FALLBACK: Helper status - Registered: ${_backgroundSipHelper!.registered}');
      }
      
      print('🔄 iOS FALLBACK: Step 4 - Setting service flags...');
      
      // Set flags for direct operation
      _isServiceRunning = true; // Force this for iOS
      _isMainAppActive = false; // Ensure background mode
      print('🏃 iOS FALLBACK: Service flags set:');
      print('  - Service Running: $_isServiceRunning');
      print('  - Main App Active: $_isMainAppActive');
      
      print('🔄 iOS FALLBACK: Step 5 - Starting SIP connection...');
      print('🚀🚀 iOS FALLBACK: Initiating SIP connection to server... 🚀🚀');
      
      // Use enhanced connection method with detailed logging
      await _connectSipInBackgroundWithDetailedLogging(sipUser);
      
      print('✅✅ iOS FALLBACK: SIP connection process completed successfully ✅✅');
      
      // Verify final status
      print('🔄 iOS FALLBACK: Step 6 - Verifying final registration status...');
      print('📊 iOS FALLBACK: Final status:');
      print('  - Helper exists: ${_backgroundSipHelper != null}');
      print('  - Helper registered: ${_backgroundSipHelper?.registered ?? false}');
      print('  - Service running: $_isServiceRunning');
      print('  - Current SIP user: ${_currentSipUser?.authUser ?? "none"}');
      
      if (_backgroundSipHelper?.registered == true) {
        print('🍎✅ iOS FALLBACK: Successfully registered to SIP server!');
        
        // Update notification to show success
        _updateServiceNotification(
          'SIP Phone (iOS Background)', 
          'Connected to SIP server - ready for calls'
        );
      } else {
        print('🍎❌ iOS FALLBACK: Registration not confirmed - may have failed');
      }
      
    } catch (e) {
      print('❌❌ iOS FALLBACK: Direct SIP registration failed with error: $e ❌❌');
      print('🔍 iOS FALLBACK: Error details: ${e.toString()}');
      print('🔍 iOS FALLBACK: Stack trace: ${StackTrace.current}');
      
      // Try one more time with a simplified approach
      print('🔄 iOS FALLBACK: Attempting simplified fallback...');
      _trySimplifiedIOSFallback();
    }
  }
  
  @pragma('vm:entry-point')
  static void _trySimplifiedIOSFallback() async {
    print('🍎🔥 iOS SIMPLIFIED: Last resort iOS background SIP registration 🔥🍎');
    
    try {
      // Get the most basic SIP configuration
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');
      
      if (savedUserJson == null) {
        print('❌ iOS SIMPLIFIED: No SIP config - giving up');
        return;
      }
      
      final sipUser = SipUser.fromJsonString(savedUserJson);
      print('📋 iOS SIMPLIFIED: Using config for ${sipUser.authUser}');
      
      // Create minimal SIP helper
      _backgroundSipHelper = SIPUAHelper();
      _currentSipUser = sipUser;
      _isServiceRunning = true;
      
      print('🚀 iOS SIMPLIFIED: Starting minimal SIP registration...');
      
      // Use the simplest possible connection
      await _connectSipMinimal(sipUser);
      
      print('✅ iOS SIMPLIFIED: Minimal registration attempt completed');
      
    } catch (e) {
      print('❌❌ iOS SIMPLIFIED: Even simplified approach failed: $e ❌❌');
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _connectSipInBackgroundWithDetailedLogging(SipUser user) async {
    try {
      print('🔌🔌🔌 DETAILED CONNECTION: Starting enhanced SIP connection process 🔌🔌🔌');
      print('📊 DETAILED: Input parameters:');
      print('  - User: ${user.authUser}');
      print('  - WebSocket URL: ${user.wsUrl}');
      print('  - Display Name: ${user.displayName}');
      
      // Always create a fresh SIP helper for iOS fallback to avoid state issues
      print('🔄 DETAILED: Creating fresh SIP helper for iOS fallback...');
      if (_backgroundSipHelper != null) {
        print('🧹 DETAILED: Cleaning up existing helper...');
        try {
          if (_backgroundSipHelper!.registered) {
            await _backgroundSipHelper!.unregister();
          }
          _backgroundSipHelper!.stop();
        } catch (e) {
          print('⚠️ DETAILED: Error cleaning up old helper: $e');
        }
        _backgroundSipHelper = null;
      }
      
      print('🆕 DETAILED: Creating completely new SIP helper instance...');
      _backgroundSipHelper = SIPUAHelper();
      print('✅ DETAILED: Fresh SIP helper created (${_backgroundSipHelper.hashCode})');
      
      // Add iOS fallback listener immediately
      print('🎧 DETAILED: Adding iOS fallback listener...');
      final listener = IOSFallbackSipListener();
      _backgroundSipHelper!.addSipUaHelperListener(listener);
      print('✅ DETAILED: Listener added to fresh helper');
      
      print('🔧 DETAILED: Setting up UA Settings...');
      UaSettings settings = UaSettings();
      
      // Parse SIP configuration with detailed logging
      String sipUri = user.sipUri ?? '';
      String username = user.authUser;
      String domain = '';
      
      print('📝 DETAILED: Parsing SIP URI: $sipUri');
      
      if (sipUri.contains('@')) {
        final parts = sipUri.split('@');
        if (parts.length > 1) {
          username = parts[0].replaceAll('sip:', '');
          domain = parts[1];
          print('📝 DETAILED: Extracted from SIP URI - Username: $username, Domain: $domain');
        }
      } else if (user.wsUrl != null && user.wsUrl!.isNotEmpty) {
        try {
          final uri = Uri.parse(user.wsUrl!);
          domain = uri.host;
          print('📝 DETAILED: Extracted domain from WebSocket URL: $domain');
        } catch (e) {
          print('⚠️ DETAILED: Failed to parse domain from WebSocket URL: $e');
          domain = 'localhost';
        }
      }
      
      String properSipUri = 'sip:$username@$domain';
      print('📝 DETAILED: Final SIP URI: $properSipUri');
      
      // Configure settings with detailed logging and validation
      print('🔧 DETAILED: Configuring and validating UA settings...');
      if (user.wsUrl == null || user.wsUrl!.isEmpty) {
        throw Exception('WebSocket URL is null or empty');
      }
      if (user.authUser.isEmpty) {
        throw Exception('Auth user is empty');
      }
      if (user.password.isEmpty) {
        throw Exception('Password is empty');
      }
      
      settings.webSocketUrl = user.wsUrl!;
      settings.webSocketSettings.extraHeaders = user.wsExtraHeaders ?? <String, dynamic>{};
      settings.uri = properSipUri;
      settings.authorizationUser = user.authUser;
      settings.password = user.password;
      settings.displayName = user.displayName;
      settings.userAgent = 'SIP Phone Flutter Background Service';
      settings.dtmfMode = DtmfMode.RFC2833;
      
      print('📝 DETAILED: Settings configured and validated:');
      print('  - WebSocket URL: ${settings.webSocketUrl}');
      print('  - SIP URI: ${settings.uri}');
      print('  - Auth User: ${settings.authorizationUser}');
      print('  - Display Name: ${settings.displayName}');
      print('  - User Agent: ${settings.userAgent}');
      
      print('🚀 DETAILED: Starting SIP helper with validated settings...');
      
      // Wrap start in try-catch to handle the null check error specifically
      try {
        _backgroundSipHelper!.start(settings);
        print('✅ DETAILED: SIP helper start() called successfully');
      } catch (startError) {
        print('❌ DETAILED: SIP helper start() failed: $startError');
        print('🔄 DETAILED: Attempting to recreate helper and retry...');
        
        // Create a completely new helper and try again
        _backgroundSipHelper = SIPUAHelper();
        final newListener = IOSFallbackSipListener();
        _backgroundSipHelper!.addSipUaHelperListener(newListener);
        
        // Try with a minimal settings configuration
        UaSettings minimalSettings = UaSettings();
        minimalSettings.webSocketUrl = user.wsUrl!;
        minimalSettings.uri = properSipUri;
        minimalSettings.authorizationUser = user.authUser;
        minimalSettings.password = user.password;
        
        print('🚀 DETAILED: Retrying with minimal settings...');
        _backgroundSipHelper!.start(minimalSettings);
        print('✅ DETAILED: SIP helper started with minimal settings');
      }
      
      // Wait longer for start to complete
      print('⏳ DETAILED: Waiting for SIP helper to fully initialize...');
      await Future.delayed(Duration(seconds: 5));
      
      // Check if the helper is ready before registering
      print('🔍 DETAILED: Checking helper readiness before registration...');
      print('  - Helper exists: ${_backgroundSipHelper != null}');
      print('  - Helper registered: ${_backgroundSipHelper?.registered ?? false}');
      
      print('📞 DETAILED: Attempting SIP registration...');
      try {
        _backgroundSipHelper!.register();
        print('✅ DETAILED: Registration call completed');
      } catch (regError) {
        print('❌ DETAILED: Registration call failed: $regError');
        rethrow;
      }
      
      print('✅✅ DETAILED CONNECTION: SIP helper started and registration attempted ✅✅');
      
      // Wait for registration confirmation with multiple checks
      print('⏳ DETAILED: Waiting for registration confirmation...');
      for (int i = 0; i < 3; i++) {
        await Future.delayed(Duration(seconds: 3));
        final isRegistered = _backgroundSipHelper?.registered ?? false;
        print('📊 DETAILED: Registration check ${i + 1}/3: $isRegistered');
        
        if (isRegistered) {
          print('🎉🎉 DETAILED: SIP registration successful! 🎉🎉');
          
          // Update notification
          _updateServiceNotification(
            'SIP Phone (iOS Connected)', 
            'Connected to $domain - ready for calls'
          );
          return;
        }
      }
      
      print('⚠️ DETAILED: Registration did not complete within timeout');
      
    } catch (e) {
      print('❌❌ DETAILED CONNECTION: Enhanced connection failed: $e ❌❌');
      print('🔍 DETAILED: Error details: ${e.toString()}');
      print('🔍 DETAILED: Stack trace: ${StackTrace.current}');
      
      // Try the simplified approach as last resort
      print('🔄 DETAILED: Falling back to simplified approach...');
      await _connectSipMinimal(user);
    }
  }
  
  @pragma('vm:entry-point')
  static Future<void> _connectSipMinimal(SipUser user) async {
    try {
      print('⚡ MINIMAL: Starting basic SIP connection with fresh helper...');
      
      // Create a completely new helper for minimal approach
      _backgroundSipHelper = SIPUAHelper();
      print('⚡ MINIMAL: New helper created (${_backgroundSipHelper.hashCode})');
      
      // Add minimal listener
      final listener = IOSFallbackSipListener();
      _backgroundSipHelper!.addSipUaHelperListener(listener);
      print('⚡ MINIMAL: Listener added');
      
      // Create minimal settings
      UaSettings settings = UaSettings();
      settings.webSocketUrl = user.wsUrl!;
      settings.uri = user.sipUri ?? 'sip:${user.authUser}@sip.ibos.io';
      settings.authorizationUser = user.authUser;
      settings.password = user.password;
      settings.displayName = user.displayName;
      settings.userAgent = 'SIP Phone iOS Minimal';
      
      print('⚡ MINIMAL: Settings prepared:');
      print('  - WebSocket URL: ${settings.webSocketUrl}');
      print('  - SIP URI: ${settings.uri}');
      print('  - Auth User: ${settings.authorizationUser}');
      
      print('🚀 MINIMAL: Starting helper with basic settings...');
      try {
        _backgroundSipHelper!.start(settings);
        print('✅ MINIMAL: Start successful');
      } catch (startError) {
        print('❌ MINIMAL: Start failed: $startError');
        return;
      }
      
      print('⏳ MINIMAL: Waiting for initialization...');
      await Future.delayed(Duration(seconds: 3));
      
      print('📞 MINIMAL: Attempting registration...');
      try {
        _backgroundSipHelper!.register();
        print('✅ MINIMAL: Registration call made');
      } catch (regError) {
        print('❌ MINIMAL: Registration failed: $regError');
        return;
      }
      
      print('⏳ MINIMAL: Waiting for registration result...');
      await Future.delayed(Duration(seconds: 5));
      
      final registered = _backgroundSipHelper?.registered ?? false;
      print('📊 MINIMAL: Final registration status: $registered');
      
      if (registered) {
        print('🎉 MINIMAL: Basic registration successful!');
        _updateServiceNotification(
          'SIP Phone (iOS Minimal)', 
          'Basic connection established - ready for calls'
        );
      } else {
        print('❌ MINIMAL: Registration did not complete');
      }
      
    } catch (e) {
      print('❌ MINIMAL: Basic connection failed: $e');
      print('❌ MINIMAL: Error details: ${e.toString()}');
    }
  }

  @pragma('vm:entry-point')
  static void _performBackgroundRegistration() async {
    try {
      print('🚀🚀🚀 ASYNC: Starting background registration process 🚀🚀🚀');
      
      // Initialize SIP helper if it doesn't exist
      if (_backgroundSipHelper == null) {
        print('🔗 ASYNC: Initializing background SIP helper for re-registration...');
        _backgroundSipHelper = SIPUAHelper();
        
        // Add listener if service instance is available
        if (_serviceInstance != null) {
          final listener = PersistentSipListener(_serviceInstance!);
          _backgroundSipHelper!.addSipUaHelperListener(listener);
          print('✅ ASYNC: Background SIP listener added during re-registration');
        } else {
          print('⚠️ ASYNC: Service instance not available for listener');
          print('⚠️ ASYNC: This suggests the service is not properly running');
        }
      } else {
        print('✅ ASYNC: Background SIP helper already exists');
      }
      
      // Check if already registered
      if (_backgroundSipHelper!.registered) {
        print('✅ ASYNC: Background SIP helper already registered');
        return;
      }
      
      // Small delay to ensure main app has unregistered first
      print('⏳ ASYNC: Waiting for main app to fully unregister...');
      await Future.delayed(Duration(seconds: 5));
      
      // Double-check main app is not active
      try {
        final prefs = await SharedPreferences.getInstance();
        final mainAppActive = prefs.getBool('main_app_is_active') ?? false;
        
        print('📊 ASYNC: Final check - Static active: $_isMainAppActive, Prefs active: $mainAppActive');
        
        if (_isMainAppActive || mainAppActive) {
          print('⚠️ ASYNC: Main app became active during re-registration - aborting');
          return;
        }
      } catch (e) {
        print('❌ ASYNC: Error checking SharedPreferences: $e');
        // Continue anyway if prefs fail
      }
      
      print('🚀🚀 ASYNC: Starting background SIP connection 🚀🚀');
      await _connectSipInBackground(_currentSipUser!);
      print('✅✅ ASYNC: Background SIP helper re-registered successfully ✅✅');
      
    } catch (e) {
      print('❌❌ ASYNC: Error re-registering background SIP helper: $e ❌❌');
      print('❌ ASYNC: Error details: ${e.toString()}');
      
      // Schedule retry
      Timer(Duration(seconds: 10), () {
        if (!_isMainAppActive && _currentSipUser != null && _isServiceRunning) {
          print('🔄 ASYNC: Retrying background SIP registration after error...');
          _performBackgroundRegistration();
        }
      });
    }
  }
  
  @pragma('vm:entry-point')
  static void _loadSipUserFromPreferences() async {
    try {
      print('📎 Loading SIP user from SharedPreferences...');
      final prefs = await SharedPreferences.getInstance();
      final savedUserJson = prefs.getString('websocket_sip_user');
      
      if (savedUserJson != null) {
        _currentSipUser = SipUser.fromJsonString(savedUserJson);
        print('✅ SIP user loaded from preferences: ${_currentSipUser!.authUser}');
        
        // Initialize background SIP helper if needed
        if (_backgroundSipHelper == null) {
          print('🔗 Initializing background SIP helper after loading user...');
          _backgroundSipHelper = SIPUAHelper();
          
          // Only add listener if service instance exists
          if (_serviceInstance != null) {
            final listener = PersistentSipListener(_serviceInstance!);
            _backgroundSipHelper!.addSipUaHelperListener(listener);
            print('✅ Background SIP helper initialized with listener');
          } else {
            print('⚠️ Background SIP helper initialized but no service instance for listener');
          }
        }
        
        // Now try re-registration again
        print('🔄 Retrying re-registration with loaded SIP user...');
        _reregisterAfterMainAppBackground();
      } else {
        print('❌ No SIP user found in SharedPreferences');
      }
    } catch (e) {
      print('❌ Error loading SIP user from preferences: $e');
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
}

/// iOS-specific fallback listener for direct SIP operation
class IOSFallbackSipListener implements SipUaHelperListener {
  IOSFallbackSipListener();

  @override
  void callStateChanged(Call call, CallState state) {
    print('🍎🔔 iOS FALLBACK: Call state changed to ${state.state}');
    print('🍎📞 iOS FALLBACK: Call from ${call.remote_identity}');
    
    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        final caller = call.remote_identity ?? 'Unknown Number';
        print('🍎🔔 iOS FALLBACK: Incoming call from $caller');
        
        // Store the incoming call reference
        PersistentBackgroundService._currentIncomingCall = call;
        
        // Show local notification for iOS
        PersistentBackgroundService.showIncomingCallNotification(
          caller: caller,
          callId: call.id ?? 'unknown',
        );
        break;
        
      case CallStateEnum.CONFIRMED:
        print('🍎✅ iOS FALLBACK: Call connected');
        if (PersistentBackgroundService._currentIncomingCall?.id == call.id) {
          PersistentBackgroundService._currentActiveCall = call;
          PersistentBackgroundService._currentIncomingCall = null;
        }
        break;
        
      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        print('🍎📞 iOS FALLBACK: Call ended/failed');
        if (PersistentBackgroundService._currentIncomingCall?.id == call.id) {
          PersistentBackgroundService._currentIncomingCall = null;
        }
        if (PersistentBackgroundService._currentActiveCall?.id == call.id) {
          PersistentBackgroundService._currentActiveCall = null;
        }
        PersistentBackgroundService.hideIncomingCallNotification();
        break;
        
      default:
        print('🍎📞 iOS FALLBACK: Call state ${state.state}');
        break;
    }
  }

  @override
  void registrationStateChanged(RegistrationState state) {
    print('🍎📋 iOS FALLBACK: Registration state changed to ${state.state}');
    
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        print('🍎✅ iOS FALLBACK: Successfully registered to SIP server!');
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        print('🍎❌ iOS FALLBACK: SIP registration failed');
        break;
      case RegistrationStateEnum.UNREGISTERED:
        print('🍎⚠️ iOS FALLBACK: SIP unregistered');
        break;
      default:
        print('🍎📋 iOS FALLBACK: Registration state ${state.state}');
        break;
    }
  }

  @override
  void transportStateChanged(TransportState state) {
    print('🍎🌐 iOS FALLBACK: Transport state changed to ${state.state}');
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {
    print('🍎📨 iOS FALLBACK: New SIP message received');
  }

  @override
  void onNewNotify(Notify ntf) {
    print('🍎📢 iOS FALLBACK: New SIP notify received');
  }

  @override
  void onNewReinvite(ReInvite event) {
    print('🍎🔄 iOS FALLBACK: New SIP re-invite received');
    if (event.reject != null) {
      event.reject!.call({'status_code': 488}); // Not acceptable here
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
        print('🔔 Background: Incoming call from $caller');
        
        // Store the incoming call reference
        PersistentBackgroundService._currentIncomingCall = call;
        
        PersistentBackgroundService.showIncomingCallNotification(
          caller: caller,
          callId: call.id ?? 'unknown',
        );
        
        // If main app is active, let it handle the call directly 
        if (PersistentBackgroundService._isMainAppActive) {
          print('📱 Main app is active - letting main app SIP helper handle call');
          print('📱 Background service will NOT interfere with main app call handling');
          // Do NOT store or forward the call - let main app handle it directly
          return; // Exit early, don't process further
        } else {
          print('📱 Main app is background - background service handling call');
          // Show enhanced notification to open app for incoming calls
          PersistentBackgroundService.showIncomingCallNotification(
            caller: caller,
            callId: call.id ?? 'unknown',
          );
        }
        
        // Auto-answer after 15 seconds ONLY if main app is NOT active
        // If main app is active, let user manually accept/decline
        Timer(Duration(seconds: 15), () {
          // Check if main app is active first
          if (PersistentBackgroundService._isMainAppActive) {
            print('📱 Main app is active - NOT auto-answering (user should handle manually)');
            return;
          }
          
          if (call.state == CallStateEnum.CALL_INITIATION || 
              call.state == CallStateEnum.PROGRESS) {
            print('⏰ Background: Checking if call needs auto-answer (app is closed)');
            print('📊 Background: Call state is still ${call.state}');
            
            try {
              // Check if call is still valid before answering
              if (call.state == CallStateEnum.CALL_INITIATION || 
                  call.state == CallStateEnum.PROGRESS) {
                // Answer the call to prevent it from failing
                final mediaConstraints = <String, dynamic>{
                  'audio': true,
                  'video': false,
                };
                call.answer(mediaConstraints);
                print('✅ Background call auto-answered after 15s timeout');
              } else {
                print('ℹ️ Call state changed, no auto-answer needed: ${call.state}');
                return;
              }
              
              // Move to active call
              PersistentBackgroundService._currentActiveCall = call;
              PersistentBackgroundService._currentIncomingCall = null;
              
              // Show notification indicating call was automatically answered
              PersistentBackgroundService._updateServiceNotification(
                'Call Auto-Answered', 
                'Active call with $caller - tap app to access controls'
              );
              
              // Keep a simple notification for the active call
              PersistentBackgroundService.showIncomingCallNotification(
                caller: 'Active: $caller (Tap to open)',
                callId: call.id ?? 'unknown',
              );
            } catch (e) {
              print('❌ Error auto-answering background call: $e');
              // Don't re-throw, just log the error
            }
          } else {
            print('📞 Background: Call state changed to ${call.state}, no auto-answer needed');
          }
        });
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
        print('📞 Background: Call ended/failed');
        // Clear call references
        if (PersistentBackgroundService._currentIncomingCall?.id == call.id) {
          PersistentBackgroundService._currentIncomingCall = null;
        }
        if (PersistentBackgroundService._currentActiveCall?.id == call.id) {
          PersistentBackgroundService._currentActiveCall = null;
        }
        // Call ended, hide notification
        PersistentBackgroundService.hideIncomingCallNotification();
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
          'SIP Phone Active', 
          'Connected and ready to receive calls'
        );
        break;
        
      case RegistrationStateEnum.REGISTRATION_FAILED:
        print('❌ Background: SIP registration failed');
        PersistentBackgroundService._updateServiceNotification(
          'SIP Phone Error', 
          'Registration failed - retrying...'
        );
        break;
        
      case RegistrationStateEnum.UNREGISTERED:
        print('⚠️ Background: SIP unregistered');
        PersistentBackgroundService._updateServiceNotification(
          'SIP Phone Disconnected', 
          'Connection lost - reconnecting...'
        );
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
        'SIP Phone Reconnecting', 
        'Network connection lost - reconnecting...'
      );
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