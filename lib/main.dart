import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
import 'sms_processor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SoftPayApp());
}

class SoftPayApp extends StatelessWidget {
  const SoftPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SoftPay Gateway',
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final Telephony telephony = Telephony.instance;
  
  final _licenseController = TextEditingController();
  final _urlController = TextEditingController();
  final _secretController = TextEditingController();
  
  bool isServiceRunning = false;
  String statusMessage = "Gateway is Inactive";

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  _loadSavedCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _licenseController.text = prefs.getString('license_key') ?? '';
      _urlController.text = prefs.getString('website_url') ?? '';
      _secretController.text = prefs.getString('secret_key') ?? '';
      isServiceRunning = prefs.getBool('is_running') ?? false;
      statusMessage = isServiceRunning ? "SoftPay Live & Syncing..." : "Gateway is Inactive";
    });
    if (isServiceRunning) {
      _initSMSSync();
    }
  }

  void _initSMSSync() {
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        SmsProcessor.processMfsSms(
          body: message.body ?? '',
          sender: message.address ?? '',
          firebaseProjectId: _secretController.text.trim(),
        );
      },
      listenInBackground: true
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SoftPay - MFS Gateway', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF007CC4),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: isServiceRunning ? Colors.green.shade100 : Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isServiceRunning ? Colors.green : Colors.orange),
                ),
                child: Row(
                  children: [
                    Icon(isServiceRunning ? Icons.check_circle : Icons.warning, color: isServiceRunning ? Colors.green : Colors.orange),
                    const SizedBox(width: 10),
                    Text(statusMessage, style: TextStyle(fontWeight: FontWeight.bold, color: isServiceRunning ? Colors.green.shade900 : Colors.orange.shade900)),
                  ],
                ),
              ),
              const SizedBox(height: 25),
              TextField(controller: _licenseController, decoration: const InputDecoration(labelText: 'SoftUp License Key', border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))))),
              const SizedBox(height: 15),
              TextField(controller: _urlController, decoration: const InputDecoration(labelText: 'Your Website URL', border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))))),
              const SizedBox(height: 15),
              TextField(controller: _secretController, decoration: const InputDecoration(labelText: 'Firebase Project ID (Secret Key)', border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))))),
              const SizedBox(height: 30),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isServiceRunning ? Colors.red : const Color(0xFF007CC4),
                  minimumSize: const Size.fromHeight(55),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                ),
                onPressed: () async {
                  SharedPreferences prefs = await SharedPreferences.getInstance();
                  if (isServiceRunning) {
                    await prefs.setBool('is_running', false);
                    setState(() {
                      isServiceRunning = false;
                      statusMessage = "Gateway is Inactive";
                    });
                  } else {
                    if(_secretController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter your Firebase Project ID")));
                      return;
                    }
                    await prefs.setString('license_key', _licenseController.text);
                    await prefs.setString('website_url', _urlController.text);
                    await prefs.setString('secret_key', _secretController.text);
                    await prefs.setBool('is_running', true);
                    
                    setState(() {
                      isServiceRunning = true;
                      statusMessage = "SoftPay Live & Syncing...";
                    });
                    _initSMSSync();
                  }
                },
                child: Text(isServiceRunning ? 'STOP SYNC SERVICE' : 'START SYNC SERVICE', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              )
            ],
          ),
        ),
      ),
    );
  }
}
