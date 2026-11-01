import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../controllers/ampel_controller.dart';

/// Full-screen camera: the first QR code that holds a valid pairing link connects this phone to the desktop.
class PairScannerScreen extends StatefulWidget {
  final AmpelController controller;
  const PairScannerScreen({super.key, required this.controller});

  @override
  State<PairScannerScreen> createState() => _PairScannerScreenState();
}

class _PairScannerScreenState extends State<PairScannerScreen> {
  bool _done = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      _done = true;
      final ok = await widget.controller.joinWithCode(raw);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      _done = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('QR-Code scannen'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Kein Kamerazugriff. Erlaube die Kamera in den Android-Einstellungen oder füge den Link unten manuell ein.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Richte die Kamera auf den QR-Code in Agent Lights am Desktop (Verbindungen).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
