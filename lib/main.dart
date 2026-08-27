import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
 
import 'sms_processor.dart';
 
// ---------------------------------------------------------------------------
// Shared preference keys
// ---------------------------------------------------------------------------
const String kPrefLicenseKey = 'softpay_license_key';
const String kPrefTargetUrl = 'softpay_target_url';
const String kPrefSecretKey = 'softpay_secret_key';
const String kPrefServiceActive = 'softpay_service_active';
 
// ---------------------------------------------------------------------------
// Background message handler (must be a top-level or static function so the
// Telephony plugin can invoke it in a headless isolate when the app is
// killed / the device is locked).
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
Future<void> backgroundMessageHandler(SmsMessage message) async {
  final prefs = await SharedPreferences.getInstance();
  final targetUrl = prefs.getString(kPrefTargetUrl) ?? '';
  final secretKey = prefs.getString(kPrefSecretKey) ?? '';
  final isActive = prefs.getBool(kPrefServiceActive) ?? false;
 
  if (!isActive || targetUrl.isEmpty || secretKey.isEmpty) return;
 
  await processMfsSms(
    message.body ?? '',
    message.address ?? '',
    targetUrl,
    secretKey,
  );
}
 
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SoftPayApp());
}
 
class SoftPayApp extends StatelessWidget {
  const SoftPayApp({super.key});
 
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoftPay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0F6E4F),
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF4F6F5),
      ),
      home: const SoftPayDashboard(),
    );
  }
}
 
class SoftPayDashboard extends StatefulWidget {
  const SoftPayDashboard({super.key});
 
  @override
  State<SoftPayDashboard> createState() => _SoftPayDashboardState();
}
 
class _SoftPayDashboardState extends State<SoftPayDashboard> {
  final Telephony telephony = Telephony.instance;
 
  final TextEditingController _licenseController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
 
  final _formKey = GlobalKey<FormState>();
 
  bool _isServiceActive = false;
  bool _isLoading = true;
  bool _permissionsGranted = false;
 
  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }
 
  @override
  void dispose() {
    _licenseController.dispose();
    _urlController.dispose();
    _secretController.dispose();
    super.dispose();
  }
 
  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------
  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _licenseController.text = prefs.getString(kPrefLicenseKey) ?? '';
      _urlController.text = prefs.getString(kPrefTargetUrl) ?? '';
      _secretController.text = prefs.getString(kPrefSecretKey) ?? '';
      _isServiceActive = prefs.getBool(kPrefServiceActive) ?? false;
      _isLoading = false;
    });
 
    // If the service was left active on last app close, re-arm the listener.
    if (_isServiceActive) {
      await _requestPermissionsAndListen(silent: true);
    }
  }
 
  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefLicenseKey, _licenseController.text.trim());
    await prefs.setString(kPrefTargetUrl, _normalizeUrl(_urlController.text));
    await prefs.setString(kPrefSecretKey, _secretController.text.trim());
  }
 
  String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
 
  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------
  String? _validateLicense(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'License key is required';
    }
    return null;
  }
 
  String? _validateUrl(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Website URL is required';
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.isScheme('HTTP') || uri.isScheme('HTTPS'))) {
      return 'Enter a valid URL, e.g. https://yourstore.com';
    }
    return null;
  }
 
  String? _validateSecret(String? value) {
    if (value == null || value.trim().length < 6) {
      return 'Secret key must be at least 6 characters';
    }
    return null;
  }
 
  // -------------------------------------------------------------------------
  // Sync service toggle
  // -------------------------------------------------------------------------
  Future<void> _toggleService() async {
    if (!_isServiceActive) {
      if (!(_formKey.currentState?.validate() ?? false)) {
        _showSnack('Please fix the highlighted fields before starting sync.');
        return;
      }
      await _saveCredentials();
      final started = await _requestPermissionsAndListen();
      if (!started) return;
 
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPrefServiceActive, true);
      setState(() => _isServiceActive = true);
      _showSnack('SoftPay Sync Service is now ACTIVE.');
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPrefServiceActive, false);
      setState(() => _isServiceActive = false);
      _showSnack('SoftPay Sync Service has been stopped.');
    }
  }
 
  Future<bool> _requestPermissionsAndListen({bool silent = false}) async {
    final bool? granted = await telephony.requestPhoneAndSmsPermissions;
 
    if (granted != true) {
      _permissionsGranted = false;
      if (!silent) {
        _showSnack('SMS permission is required to start the sync service.');
      }
      return false;
    }
 
    _permissionsGranted = true;
 
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) async {
        // Foreground listener — used while the app is open/backgrounded
        // but not killed. Delegates to the same processing pipeline used
        // by the headless background handler for consistency.
        final prefs = await SharedPreferences.getInstance();
        final targetUrl = prefs.getString(kPrefTargetUrl) ?? '';
        final secretKey = prefs.getString(kPrefSecretKey) ?? '';
        await processMfsSms(
          message.body ?? '',
          message.address ?? '',
          targetUrl,
          secretKey,
        );
      },
      onBackgroundMessage: backgroundMessageHandler,
      listenInBackground: true,
    );
 
    return true;
  }
 
  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
 
  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
 
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SoftPay',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStatusBanner(),
                const SizedBox(height: 24),
                const Text(
                  'Gateway Configuration',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect SoftPay to your WooCommerce store to auto-verify MFS transactions.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 20),
                _buildCard(
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _licenseController,
                        enabled: !_isServiceActive,
                        decoration: const InputDecoration(
                          labelText: 'SoftUp License Key',
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateLicense,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _urlController,
                        enabled: !_isServiceActive,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Target E-commerce Website URL',
                          hintText: 'https://yourstore.com',
                          prefixIcon: Icon(Icons.language_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateUrl,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _secretController,
                        enabled: !_isServiceActive,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Custom Local Secret Key',
                          prefixIcon: Icon(Icons.lock_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateSecret,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                _buildToggleButton(),
                const SizedBox(height: 12),
                if (_isServiceActive)
                  Center(
                    child: TextButton.icon(
                      onPressed: () async {
                        setState(() => _isServiceActive = false);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(kPrefServiceActive, false);
                        // Allow editing again after explicit stop via toggle.
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit configuration'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
 
  Widget _buildStatusBanner() {
    final Color bg = _isServiceActive
        ? const Color(0xFFE6F4EA)
        : const Color(0xFFF5EAEA);
    final Color fg = _isServiceActive
        ? const Color(0xFF0F6E4F)
        : const Color(0xFF8A3B3B);
    final IconData icon =
        _isServiceActive ? Icons.check_circle : Icons.pause_circle_outline;
 
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isServiceActive ? 'Sync Service: ACTIVE' : 'Sync Service: INACTIVE',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isServiceActive
                      ? 'Listening for incoming bKash / Nagad SMS notifications.'
                      : 'Enter your credentials and start the service below.',
                  style: TextStyle(color: fg.withOpacity(0.85), fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
 
  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
 
  Widget _buildToggleButton() {
    return SizedBox(
      height: 58,
      child: ElevatedButton(
        onPressed: _toggleService,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              _isServiceActive ? const Color(0xFFB3261E) : const Color(0xFF0F6E4F),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: Text(
          _isServiceActive ? 'STOP SYNC SERVICE' : 'START SYNC SERVICE',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
 