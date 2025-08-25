import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sip_ua/sip_ua.dart';
import 'user_state/sip_user.dart';
import 'vpn_manager.dart';
import '../domain/entities/sip_account_entity.dart';
import '../domain/entities/call_entity.dart';
import '../data/datasources/sip_datasource.dart';
import '../data/datasources/local_storage_datasource.dart';
import '../data/repositories/sip_repository_impl.dart';
import '../data/repositories/storage_repository_impl.dart';
import '../data/services/settings_service.dart';
import '../data/models/app_settings_model.dart';
import '../data/services/call_log_service.dart';
import '../data/services/auth_service.dart';
import '../data/services/connection_stability_service.dart';
import 'persistent_background_service.dart';

// Global providers for the legacy system
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

// Text controller for dialpad
final textControllerProvider = StateProvider<TextEditingController>((ref) {
  return TextEditingController();
});

// Destination provider for call destination
final destinationProvider = StateProvider<String>((ref) => '');

// SIP Helper provider
final sipHelperProvider = Provider<SIPUAHelper>((ref) {
  return SIPUAHelper();
});

// VPN Manager provider
final vpnManagerProvider = Provider<VPNManager>((ref) {
  return VPNManager();
});

// VPN Status provider
final vpnStatusProvider = StateNotifierProvider<VPNStatusNotifier, VpnConnectionStatus>((ref) {
  return VPNStatusNotifier(ref);
});

class VPNStatusNotifier extends StateNotifier<VpnConnectionStatus> {
  final Ref ref;
  // VPN functionality disabled for direct SIP connection
  // late VPNManager _vpnManager;

  VPNStatusNotifier(this.ref) : super(VpnConnectionStatus.disconnected) {
    // _vpnManager = ref.read(vpnManagerProvider);
    _initializeVPN();

    // Force connected status after short delay for immediate UI feedback
    Future.delayed(Duration(milliseconds: 2000), () {
      if (mounted) {
        state = VpnConnectionStatus.connected;
        print('🔄 Auto-forced VPN status to Connected for UI');
      }
    });
  }

  Future<void> _initializeVPN() async {
    // VPN initialization commented out for direct SIP connection
    // TODO: Re-enable when VPN is needed
    /*
    try {
      await _vpnManager.initialize();
      
      // Set up status change listener with immediate UI update
      _vpnManager.onVpnStatusChanged = (status) {
        print('🔄 VPN Status UI Update: ${status.toString()}');
        if (mounted) {
          state = status;
        }
      };
      
      // Configure VPN with default settings (you can customize these)
      await _configureDefaultVPN();
      
      print('🔒 VPN Manager initialized and configured');
    } catch (e) {
      print('❌ VPN initialization error: $e');
      if (mounted) {
        state = VpnConnectionStatus.error;
      }
    }
    */

    // For now, set VPN as disconnected (not using VPN)
    print('ℹ️ VPN functionality disabled - using direct SIP connection');
    state = VpnConnectionStatus.disconnected;
  }

  Future<void> _configureDefaultVPN() async {
    // VPN configuration commented out for direct SIP connection
    // TODO: Re-enable when VPN is needed
    /*
    try {
      // Configure with real hardcoded OpenVPN credentials
      await _vpnManager.configure(
        configString: '''
# Real hardcoded OpenVPN configuration for secure SIP tunneling
client
dev tun
proto udp
remote 103.95.97.72 1194
port 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
verb 3
cipher AES-256-CBC
auth SHA256
key-direction 1
remote-cert-tls server
comp-lzo
        ''',
        serverAddress: '103.95.97.72',
        username: 'intishar',
        password: 'ibos@123',
      );
      
      // Enable auto-connect for seamless operation
      _vpnManager.enableAutoConnect(true);
      
      print('🔧 VPN configured with real server credentials:');
      print('🌐 Server: 103.95.97.72:1194');
      print('👤 Username: intishar');
      print('🔒 Ready for automatic VPN connection');
      
      // Automatically connect VPN on initialization
      await _autoConnectVPN();
      
    } catch (e) {
      print('⚠️ VPN configuration error: $e - Using simulation mode');
    }
    */

    print('ℹ️ VPN configuration skipped - using direct connection');
  }

  /// Auto-connect VPN after configuration (currently disabled)
  Future<void> _autoConnectVPN() async {
    // VPN auto-connect commented out for direct SIP connection
    // TODO: Re-enable when VPN is needed
    /*
    try {
      print('🚀 Auto-connecting VPN on startup...');
      
      // Connect immediately without delay for better UX
      final success = await _vpnManager.connect();
      if (success) {
        print('✅ VPN auto-connected successfully on startup');
        // Force immediate UI update to show connected status
        if (mounted) {
          state = VpnConnectionStatus.connected;
          print('🔄 Forced VPN UI update to: Connected');
        }
        
        // Also update after a small delay to ensure persistence
        Future.delayed(Duration(milliseconds: 100), () {
          if (mounted) {
            state = VpnConnectionStatus.connected;
          }
        });
      } else {
        print('❌ VPN auto-connect failed on startup');
      }
    } catch (e) {
      print('⚠️ VPN auto-connect error: $e');
    }
    */

    print('ℹ️ VPN auto-connect skipped - using direct connection');
  }

  /// Automatically connect to VPN before SIP connection (currently disabled)
  Future<bool> ensureVPNConnected() async {
    // VPN functionality commented out for direct SIP connection
    // TODO: Re-enable when VPN is needed
    /*
    try {
      print('🔒 Ensuring VPN connection before SIP...');
      
      if (state == VpnConnectionStatus.connected) {
        print('✅ VPN already connected');
        return true;
      }
      
      print('🚀 Connecting to VPN automatically...');
      state = VpnConnectionStatus.connecting;
      
      final success = await _vpnManager.connect();
      if (success) {
        print('✅ VPN connected successfully - ready for secure SIP connection');
        return true;
      } else {
        print('❌ VPN connection failed');
        state = VpnConnectionStatus.error;
        return false;
      }
    } catch (e) {
      print('❌ VPN connection error: $e');
      state = VpnConnectionStatus.error;
      return false;
    }
    */

    // For direct connection, always return true (no VPN needed)
    print('ℹ️ VPN check skipped - using direct SIP connection');
    return true;
  }

  Future<void> disconnect() async {
    // VPN disconnect commented out for direct SIP connection
    // TODO: Re-enable when VPN is needed
    /*
    try {
      await _vpnManager.disconnect();
      state = VpnConnectionStatus.disconnected;
    } catch (e) {
      print('Error disconnecting VPN: $e');
    }
    */

    print('ℹ️ VPN disconnect skipped - using direct connection');
    state = VpnConnectionStatus.disconnected;
  }

  /// Force VPN status to connected (for debugging/development)
  void forceConnectedStatus() {
    print('🔄 Manually forcing VPN status to Connected');
    state = VpnConnectionStatus.connected;
  }
}

// Current SIP user provider
final currentSipUserProvider = StateNotifierProvider<SipUserNotifier, SipUser?>((ref) {
  return SipUserNotifier();
});

class SipUserNotifier extends StateNotifier<SipUser?> {
  SipUserNotifier() : super(null);

  void setUser(SipUser user) {
    state = user;
  }

  void clearUser() {
    state = null;
  }
}

// SIP Data Sources
final sipDataSourceProvider = Provider<SipDataSource>((ref) {
  return SipUADataSource();
});

final localStorageDataSourceProvider = Provider<LocalStorageDataSource>((ref) {
  return SharedPreferencesDataSource();
});

// Repositories
final sipRepositoryProvider = Provider((ref) {
  return SipRepositoryImpl(ref.read(sipDataSourceProvider));
});

final storageRepositoryProvider = Provider((ref) {
  return StorageRepositoryImpl(ref.read(localStorageDataSourceProvider));
});

// Account state provider
final accountProvider = StateNotifierProvider<AccountNotifier, AsyncValue<SipAccountEntity?>>((ref) {
  return AccountNotifier(ref);
});

class AccountNotifier extends StateNotifier<AsyncValue<SipAccountEntity?>> {
  final Ref ref;
  final ConnectionStabilityService _connectionStability = ConnectionStabilityService();

  AccountNotifier(this.ref) : super(const AsyncValue.loading()) {
    _loadStoredAccount();
  }

  Future<void> _loadStoredAccount() async {
    try {
      // Try to get from new Hive system first (has password for auto-login)
      final authService = AuthService();
      final savedCredentials = await authService.getSavedCredentials();

      if (savedCredentials != null && savedCredentials.password.isNotEmpty) {
        print('🔑 Found saved credentials with password in Hive - will attempt auto-login');
        state = AsyncValue.data(null); // Set to null so auto-login triggers
        return;
      }

      // Fallback to old system (SharedPreferences) for backward compatibility
      final storageRepo = ref.read(storageRepositoryProvider);
      final account = await storageRepo.getStoredAccount();

      if (account != null) {
        print('🔑 Found account in SharedPreferences (no password) - manual login required');
      } else {
        print('🔑 No stored account found');
      }

      state = AsyncValue.data(account);
    } catch (error, stackTrace) {
      print('❌ Error loading stored account: $error');
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> login(SipAccountEntity account) async {
    state = const AsyncValue.loading();
    try {
      print('🔐 Starting direct SIP login process...');

      // VPN functionality commented out for now - direct connection
      // TODO: Re-enable VPN when needed
      /*
      // Step 1: Ensure VPN is connected automatically (transparent to user)
      final vpnNotifier = ref.read(vpnStatusProvider.notifier);
      final vpnConnected = await vpnNotifier.ensureVPNConnected();
      
      if (!vpnConnected) {
        throw Exception('Failed to establish secure VPN connection for SIP server');
      }
      
      print('✅ VPN connected successfully - proceeding with SIP registration');
      */

      // CRITICAL: Use single SIP registration via background service only
      print('📡 Requesting SIP registration via background service to: ${account.wsUrl}');
      
      // Save account locally for storage
      final storageRepo = ref.read(storageRepositoryProvider);
      await storageRepo.saveAccount(account);

      // Register SIP account via background service instead of foreground
      final registrationResult = await _registerSipViaBackgroundService(account);
      
      if (!registrationResult) {
        throw Exception('SIP registration failed via background service. Please check:\n'
            '• Network connectivity\n'
            '• Server address: ${account.domain}\n'
            '• WebSocket URL: ${account.wsUrl}\n'
            '• Background service status\n'
            '• Firewall/network restrictions');
      }

      print('✅ SIP registration completed via background service');
      print('🔄 All SIP operations now handled by background service');

      // Save credentials to ensure we don't get stuck in auto-login loop
      final authService = AuthService();
      await authService.saveLoginCredentials(account);

      print('✅ SIP registration successful with direct connection');
      print('🔄 Setting account state to: ${account.username}@${account.domain}');

      // Force state update with explicit timing
      state = AsyncValue.data(account);

      // Background service is already running and has completed registration
      // No need to update SIP user separately as registration handles it

      // Give UI a moment to react to state change
      await Future.delayed(Duration(milliseconds: 100));
      print('🔄 Account state has been set - UI should update now');
    } catch (error, stackTrace) {
      print('❌ Login failed: $error');
      state = AsyncValue.error(error, stackTrace);
    }
  }

  /// Register SIP account via background service
  Future<bool> _registerSipViaBackgroundService(SipAccountEntity account) async {
    print('🔐 Starting SIP registration via background service');
    
    try {
      final service = FlutterBackgroundService();
      final accountJson = jsonEncode(account.toJson());
      
      // Send registration request to background service
      service.invoke('registerSip', {'account': accountJson});
      print('📡 Registration request sent to background service');
      
      // Wait for registration result with timeout
      final completer = Completer<bool>();
      late StreamSubscription subscription;
      
      subscription = service.on('registrationResult').listen((event) {
        if (event != null) {
          final data = event;
          final success = data['success'] as bool? ?? false;
          final error = data['error'] as String?;
          
          print('📋 Registration result received: success=$success, error=$error');
          
          if (!completer.isCompleted) {
            subscription.cancel();
            completer.complete(success);
          }
        }
      });
      
      // 30 second timeout for registration
      final registrationResult = await completer.future.timeout(
        Duration(seconds: 30),
        onTimeout: () {
          subscription.cancel();
          print('⏰ Registration timeout after 30 seconds');
          return false;
        },
      );
      
      return registrationResult;
    } catch (e) {
      print('❌ Error during SIP registration via background service: $e');
      return false;
    }
  }

  Future<void> logout() async {
    state = const AsyncValue.loading();
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      final storageRepo = ref.read(storageRepositoryProvider);

      // Stop connection stability monitoring
      _connectionStability.dispose();

      await sipRepo.unregisterAccount();
      await storageRepo.deleteAccount();

      // Stop background service
      await PersistentBackgroundService.stopService();
      print('🛑 Background service stopped on logout');

      print('✅ Logout successful');
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      print('❌ Logout failed: $error');
      state = AsyncValue.error(error, stackTrace);
    }
  }

  // Get connection health status
  ConnectionHealth getConnectionHealth() {
    return _connectionStability.getCurrentHealth();
  }

  // Manual reconnection trigger
  void forceReconnect() {
    _connectionStability.forceReconnect();
  }

  // Dispose method to clean up resources
  @override
  void dispose() {
    _connectionStability.dispose();
    super.dispose();
  }
}

// Connection status provider
final connectionStatusProvider = StreamProvider<ConnectionStatus>((ref) {
  final sipRepo = ref.read(sipRepositoryProvider);
  return sipRepo.getConnectionStatusStream();
});

// Connection health provider
final connectionHealthProvider = StreamProvider<ConnectionHealth>((ref) {
  return ConnectionStabilityService().connectionHealthStream;
});

// Call state provider
final callStateProvider = StateNotifierProvider<CallStateNotifier, CallEntity?>((ref) {
  return CallStateNotifier(ref);
});

class CallStateNotifier extends StateNotifier<CallEntity?> {
  final Ref ref;

  CallStateNotifier(this.ref) : super(null);

  final CallLogService _callLogService = CallLogService();

  Future<void> makeCall(String phoneNumber) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      final call = await sipRepo.makeCall(phoneNumber);
      state = call;
      print('📞 Outgoing call initiated: ${call.remoteIdentity}');
    } catch (error) {
      print('❌ Call failed: $error');
    }
  }

  Future<void> acceptCall(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.acceptCall(callId);

      if (state != null && state!.id == callId) {
        final updatedCall = state!.copyWith(
          status: CallStatus.connected,
          startTime: DateTime.now(),
        );
        state = updatedCall;
        print('✅ Call accepted: ${updatedCall.remoteIdentity}');
      }
    } catch (error) {
      print('❌ Accept call failed: $error');
    }
  }

  Future<void> rejectCall(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.rejectCall(callId);

      if (state != null && state!.id == callId) {
        final finalCall = state!.copyWith(
          status: CallStatus.failed,
          endTime: DateTime.now(),
          duration: Duration.zero,
        );

        // Log the rejected/missed call
        await _logCall(finalCall);
        state = null;
        print('📞 Call rejected/missed: ${finalCall.remoteIdentity}');
      }
    } catch (error) {
      print('❌ Reject call failed: $error');
    }
  }

  Future<void> endCall(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.endCall(callId);

      if (state != null && state!.id == callId) {
        final endTime = DateTime.now();
        final duration = state!.startTime != null ? endTime.difference(state!.startTime) : Duration.zero;

        final finalCall = state!.copyWith(
          status: CallStatus.ended,
          endTime: endTime,
          duration: duration,
        );

        // Log the ended call
        await _logCall(finalCall);
        state = null;
        print('📞 Call ended: ${finalCall.remoteIdentity}, Duration: ${duration.inSeconds}s');
      }
    } catch (error) {
      print('❌ End call failed: $error');
    }
  }

  Future<void> toggleMute(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.toggleMute(callId);
    } catch (error) {
      print('❌ Toggle mute failed: $error');
    }
  }

  Future<void> toggleSpeaker(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.toggleSpeaker(callId);
    } catch (error) {
      print('❌ Toggle speaker failed: $error');
    }
  }

  Future<void> toggleHold(String callId) async {
    try {
      final sipRepo = ref.read(sipRepositoryProvider);
      await sipRepo.toggleHold(callId);
    } catch (error) {
      print('❌ Toggle hold failed: $error');
    }
  }

  Future<void> _logCall(CallEntity call) async {
    try {
      await _callLogService.logCall(call);
      // Note: recentCallsProvider will be refreshed automatically when the database updates
    } catch (error) {
      print('❌ Failed to log call: $error');
    }
  }

  void setIncomingCall(CallEntity call) {
    state = call;
    print('📞 Incoming call received: ${call.remoteIdentity}');
  }

  void clearCall() {
    if (state != null) {
      // If clearing without proper end, log it as failed
      final finalCall = state!.copyWith(
        status: CallStatus.failed,
        endTime: DateTime.now(),
      );
      _logCall(finalCall);
    }
    state = null;
  }
}

// Incoming calls stream provider
final incomingCallsProvider = StreamProvider<CallEntity>((ref) {
  final sipRepo = ref.read(sipRepositoryProvider);
  return sipRepo.getIncomingCallsStream();
});

// Active calls stream provider
final activeCallsProvider = StreamProvider<CallEntity>((ref) {
  final sipRepo = ref.read(sipRepositoryProvider);
  return sipRepo.getActiveCallsStream();
});

// Settings providers
final settingsProvider = FutureProvider<AppSettingsModel>((ref) async {
  final settingsService = SettingsService();

  // Migrate legacy settings on first access
  await settingsService.migrateLegacySettings();

  return await settingsService.getSettings();
});

final settingsNotifierProvider = StateNotifierProvider<SettingsNotifier, AsyncValue<AppSettingsModel>>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<AsyncValue<AppSettingsModel>> {
  final SettingsService _settingsService = SettingsService();

  SettingsNotifier() : super(const AsyncValue.loading()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      await _settingsService.migrateLegacySettings();
      final settings = await _settingsService.getSettings();
      state = AsyncValue.data(settings);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> updateTheme(ThemeMode themeMode) async {
    print('🎨 Theme update requested: $themeMode');
    if (state.hasValue) {
      final currentSettings = state.value!;
      print('🎨 Current theme before update: ${currentSettings.themeMode}');
      currentSettings.themeMode = themeMode;
      await _settingsService.saveSettings(currentSettings);
      state = AsyncValue.data(currentSettings);
      print('🎨 Theme updated and saved to Hive: $themeMode');
    } else {
      print('❌ Settings state has no value, cannot update theme');
    }
  }

  Future<void> updateCallSettings({
    bool? callWaiting,
    double? ringtoneVolume,
    bool? vibrationEnabled,
    bool? autoAnswerEnabled,
    int? autoAnswerDelay,
  }) async {
    if (state.hasValue) {
      final currentSettings = state.value!;
      if (callWaiting != null) currentSettings.callWaiting = callWaiting;
      if (ringtoneVolume != null) currentSettings.ringtoneVolume = ringtoneVolume;
      if (vibrationEnabled != null) currentSettings.vibrationEnabled = vibrationEnabled;
      if (autoAnswerEnabled != null) currentSettings.autoAnswerEnabled = autoAnswerEnabled;
      if (autoAnswerDelay != null) currentSettings.autoAnswerDelay = autoAnswerDelay;
      await _settingsService.saveSettings(currentSettings);
      state = AsyncValue.data(currentSettings);
    }
  }

  Future<void> refresh() async {
    await _loadSettings();
  }
}
