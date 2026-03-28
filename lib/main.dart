import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:gocartpos/pos_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  bool isFirebaseInitialized = false;
  String? initializationError;

  try {
    // Note: For Windows/Web, you may need to pass FirebaseOptions(...) here
    await Firebase.initializeApp();
    isFirebaseInitialized = true;
  } catch (e) {
    initializationError = e.toString();
    debugPrint('Firebase initialization failed: $e');
  }

  runApp(MyApp(
    isInitialized: isFirebaseInitialized, 
    error: initializationError
  ));
}

class MyApp extends StatelessWidget {
  final bool isInitialized;
  final String? error;

  const MyApp({super.key, required this.isInitialized, this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoCart POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      // Pass initialization info to the POS screen
      home: POSScreen(isInitialized: isInitialized, initializationError: error),
    );
  }
}
