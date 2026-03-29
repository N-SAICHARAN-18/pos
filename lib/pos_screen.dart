import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:gocartpos/scanner_screen.dart';

/// Item model representing a product in the cart
class CartItem {
  final String id;
  String name;
  int qty;
  double price; // Represents the total manually entered amount
  String expiryDate;

  CartItem({
    required this.id,
    required this.name,
    this.qty = 1,
    required this.price,
    this.expiryDate = '',
  });

  double get amount => price; // Return price directly as it's manually entered

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'qty': qty,
      'price': price,
      'expiryDate': expiryDate,
    };
  }

  factory CartItem.fromMap(Map<String, dynamic> map) {
    return CartItem(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      qty: map['qty'] ?? 1,
      price: (map['price'] ?? 0.0).toDouble(),
      expiryDate: map['expiryDate'] ?? '',
    );
  }
}

class POSScreen extends StatefulWidget {
  final bool isInitialized;
  final String? initializationError;

  const POSScreen({super.key, required this.isInitialized, this.initializationError});

  @override
  State<POSScreen> createState() => _POSScreenState();
}

class _POSScreenState extends State<POSScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final String _sessionId = "session_1";
  List<CartItem> cartItems = [];
  double totalAmount = 0; // State variable for billing total

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  DocumentReference get _sessionRef => _firestore.collection('pos_sessions').doc(_sessionId);

  @override
  void initState() {
    super.initState();
    // Listen to firestore for real-time sync with other devices
    if (widget.isInitialized) {
      _sessionRef.snapshots().listen((snapshot) {
        if (snapshot.exists) {
          final data = snapshot.data() as Map<String, dynamic>;
          final List<dynamic> itemsData = data['items'] ?? [];
          setState(() {
            cartItems = itemsData.map((e) => CartItem.fromMap(e as Map<String, dynamic>)).toList();
          });
        }
      });
    }
  }

  /// ADDS an item to Firestore
  Future<void> _addItem(String id, String name, double price, {String expiryDate = ''}) async {
    if (!widget.isInitialized) return;

    final doc = await _sessionRef.get();
    List<dynamic> itemsData = [];
    if (doc.exists) {
      itemsData = (doc.data() as Map<String, dynamic>)['items'] ?? [];
    }

    List<CartItem> items = itemsData.map((e) => CartItem.fromMap(e as Map<String, dynamic>)).toList();
    
    // Check if item already exists in cart, increment qty if so
    int existingIndex = items.indexWhere((element) => element.id == id);
    if (existingIndex != -1) {
      items[existingIndex].qty += 1;
    } else {
      items.add(CartItem(id: id, name: name, price: price, qty: 1, expiryDate: expiryDate));
    }

    await _sessionRef.set({
      'items': items.map((e) => e.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// REMOVES an item from Firestore
  Future<void> _removeItem(int index) async {
    if (!widget.isInitialized) return;

    final doc = await _sessionRef.get();
    if (!doc.exists) return;

    List<dynamic> items = (doc.data() as Map<String, dynamic>)['items'] ?? [];
    if (index >= 0 && index < items.length) {
      items.removeAt(index);
    }

    await _sessionRef.update({
      'items': items,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// CLEARS the current session
  Future<void> _clearCart() async {
    if (!widget.isInitialized) return;

    await _sessionRef.update({
      'items': [],
      'updatedAt': FieldValue.serverTimestamp(),
    });
    setState(() {
      cartItems = [];
    });
    _phoneController.clear();
  }

  /// NEW: Show dialog to manually edit item details
  void _showEditItemDialog(int index) {
    if (index < 0 || index >= cartItems.length) return;
    
    final item = cartItems[index];
    final nameController = TextEditingController(text: item.name);
    final expiryController = TextEditingController(text: item.expiryDate);
    final amountController = TextEditingController(text: item.price.toStringAsFixed(2));

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Item: ${item.id}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Description')),
            TextField(
              controller: expiryController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Expiry Date',
                hintText: 'MM/YY',
                suffixIcon: Icon(Icons.calendar_month),
              ),
              onTap: () async {
                final DateTime? picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2101),
                );
                if (picked != null) {
                  final String day = picked.day.toString().padLeft(2, '0');
                  final String month = picked.month.toString().padLeft(2, '0');
                  final String year = picked.year.toString().substring(2);
                  expiryController.text = '$day-$month-$year';
                }
              },
            ),
            TextField(controller: amountController, decoration: const InputDecoration(labelText: 'Total Amount (₹)'), keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                item.name = nameController.text.trim();
                item.expiryDate = expiryController.text.trim();
                item.price = double.tryParse(amountController.text) ?? 0.0;
              });
              // Update Firestore sync
              await _sessionRef.set({
                'items': cartItems.map((e) => e.toMap()).toList(),
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
              if (mounted) Navigator.pop(context);
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  /// REFINED: Fetch product name via Open Food Facts (OFF) API
  Future<String?> getProductName(String barcode) async {
    try {
      final response = await http.get(Uri.parse("https://world.openfoodfacts.org/api/v0/product/$barcode.json"));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print("OFF response: ${response.body}"); // Matching request for logging
        if (data['status'] == 1) {
          return data['product']['product_name'];
        }
      }
    } catch (_) {}
    return null;
  }

  /// THE REQUESTED HANDLER: Handle scanned barcode with fallback and state update
  Future<void> handleScannedBarcode(String barcode) async {
    print("Scanned barcode: $barcode");
    String? productName;

    // STEP 1: OpenFoodFacts API
    productName = await getProductName(barcode);

    // STEP 2: Fallback to FoodRepo
    if (productName == null || productName.isEmpty) {
      try {
        final response2 = await http.get(Uri.parse("https://www.foodrepo.org/api/v3/products/$barcode"));
        print("FoodRepo response: ${response2.body}");
        if (response2.statusCode == 200) {
          final data2 = jsonDecode(response2.body);
          productName = data2['data']['display_name'];
        }
      } catch (_) {}
    }

    print("Final productName: $productName");

    // STEP 3: HANDLE RESULT
    if (productName != null && productName.isNotEmpty) {
      setState(() {
        // Checking for duplicates before adding
        int existingIndex = cartItems.indexWhere((element) => element.id == barcode);
        if (existingIndex != -1) {
          cartItems[existingIndex].qty += 1;
        } else {
          cartItems.add(
            CartItem(
              id: barcode,
              name: productName!,
              price: 0, 
              qty: 1,
            ),
          );
        }
      });
      // Sync with Firestore for real-time updates across devices
      await _addItem(barcode, productName, 0);
    } else {
      print("Product not found");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Product not found in OpenFoodFacts or FoodRepo')));
        _showManualEntryDialog(barcode);
      }
    }
  }

  /// FETCH product by barcode (Legacy wrapper)
  Future<void> _fetchProductByBarcode(String barcode) async {
    await handleScannedBarcode(barcode);
  }

  /// ASK for price and save to products collection
  void _askPriceAndSave(String barcode, String name) {
    final priceController = TextEditingController();
    final expiryController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Found: $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: priceController,
              decoration: const InputDecoration(labelText: 'Enter Price (₹)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: expiryController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Expiry Date',
                hintText: 'MM/YY',
                suffixIcon: Icon(Icons.calendar_month),
              ),
              onTap: () async {
                final DateTime? picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2101),
                );
                if (picked != null) {
                  final String day = picked.day.toString().padLeft(2, '0');
                  final String month = picked.month.toString().padLeft(2, '0');
                  final String year = picked.year.toString().substring(2);
                  expiryController.text = '$day-$month-$year';
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              double price = double.tryParse(priceController.text) ?? 0.0;
              String expiry = expiryController.text.trim();
              await _firestore.collection('products').doc(barcode).set({
                'name': name,
                'price': price,
              });
              _addItem(barcode, name, price, expiryDate: expiry);
              if (mounted) Navigator.pop(context);
            },
            child: const Text('ADD TO CART'),
          ),
        ],
      ),
    );
  }

  /// SHOW manual entry dialog
  void _showManualEntryDialog(String barcode) {
    final nameController = TextEditingController();
    final priceController = TextEditingController();
    final expiryController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Product Not Found'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Barcode: $barcode', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Product Name')),
            TextField(controller: priceController, decoration: const InputDecoration(labelText: 'Price (₹)'), keyboardType: TextInputType.number),
            TextField(
              controller: expiryController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Expiry Date',
                hintText: 'MM/YY',
                suffixIcon: Icon(Icons.calendar_month),
              ),
              onTap: () async {
                final DateTime? picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2101),
                );
                if (picked != null) {
                  final String day = picked.day.toString().padLeft(2, '0');
                  final String month = picked.month.toString().padLeft(2, '0');
                  final String year = picked.year.toString().substring(2);
                  expiryController.text = '$day-$month-$year';
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              String name = nameController.text.trim();
              double price = double.tryParse(priceController.text) ?? 0.0;
              String expiry = expiryController.text.trim();
              if (name.isNotEmpty) {
                await _firestore.collection('products').doc(barcode).set({'name': name, 'price': price});
                _addItem(barcode, name, price, expiryDate: expiry);
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text('SAVE & ADD'),
          ),
        ],
      ),
    );
  }

  /// SHOW scanner screen and handle result
  void _showScannerDialog() async {
    final String? barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const ScannerScreen()),
    );

    if (barcode != null && barcode.isNotEmpty) {
      handleScannedBarcode(barcode);
    }
  }

  /// SHOWS the billing popup
  void _showCheckoutDialog(List<CartItem> items, double total) {
    if (!widget.isInitialized || items.isEmpty) return;

    final nameController = TextEditingController();
    final checkoutPhoneController = TextEditingController(text: _phoneController.text);
    String selectedMethod = 'Cash';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: const RoundedRectangleBorder(),
          title: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: Colors.blueGrey[900],
            child: const Center(
              child: Text(
                'FINAL BILLING & PAY',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
          titlePadding: EdgeInsets.zero,
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('CUSTOMER DETAILS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Customer Name', isDense: true),
                ),
                TextField(
                  controller: checkoutPhoneController,
                  decoration: const InputDecoration(labelText: 'Phone Number', isDense: true),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 25),
                const Text('PAYMENT MODE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedMethod,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  onChanged: (val) => setDialogState(() => selectedMethod = val!),
                  items: ['Cash', 'UPI', 'Card']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                ),
                const SizedBox(height: 25),
                Container(
                  padding: const EdgeInsets.all(15),
                  color: Colors.green[50],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('TOTAL PAYABLE:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text('₹${total.toStringAsFixed(2)}', 
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () async {
                final String customerName = nameController.text.trim();
                final String phoneNumber = checkoutPhoneController.text.trim();
                final String paymentMode = selectedMethod;

                if (phoneNumber.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Phone number required')));
                  return;
                }

                // --- START SAVE LOGIC ---
                try {
                  print("Saving bill to 'orders' collection...");
                  
                  // Convert items to Map
                  final itemsList = items.map((item) => {
                    'name': item.name,
                    'qty': item.qty,
                    'price': item.price,
                    'expiryDate': item.expiryDate,
                  }).toList();

                  // Requirement 1 & 7: Collection 'orders' with specified fields
                  await FirebaseFirestore.instance.collection('orders').add({
                    'phone': phoneNumber,
                    'customerName': customerName,
                    'items': itemsList,
                    'total': total,
                    'paymentMode': paymentMode,
                    'timestamp': FieldValue.serverTimestamp(),
                  });

                  print("Save successful!");
                  
                  if (context.mounted) {
                    Navigator.pop(context); // close dialog
                    
                    // Requirement 6: Clear cart and show success message
                    _clearCart(); 
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Bill Saved & Paid Successfully!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  print("SAVE FAILED: $e");
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to save: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[800],
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(),
              ),
              child: const Text('PAY & SAVE [F12]'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isInitialized) {
      return _buildSetupRequiredScreen();
    }

    final subTotal = cartItems.fold(0.0, (sum, item) => sum + item.amount);
    final total = subTotal;

    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isMobile = constraints.maxWidth <= 800;

          return Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: isMobile
                    ? SingleChildScrollView(
                        child: Column(
                          children: [
                            SizedBox(height: 450, child: _buildBillingArea(cartItems)),
                            _buildSummaryPanel(subTotal, total, cartItems),
                          ],
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 7, child: _buildBillingArea(cartItems)),
                          Expanded(flex: 3, child: _buildSummaryPanel(subTotal, total, cartItems)),
                        ],
                      ),
              ),
              _buildBottomBar(total),
            ],
          );
        },
      ),
    );
  }

  /// NEW: Fallback screen when Firebase is not configured properly
  Widget _buildSetupRequiredScreen() {
    return Scaffold(
      backgroundColor: Colors.blueGrey[900],
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 60, color: Colors.red),
              const SizedBox(height: 20),
              const Text('FIREBASE SETUP REQUIRED', 
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 15),
              Text(
                'The app failed to connect to Firebase. This usually means the configuration file is missing or invalid.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 25),
              const Divider(),
              const SizedBox(height: 15),
              const Text('HOW TO FIX:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 10),
              const Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('1. Go to Firebase Console'),
                    Text('2. Download google-services.json'),
                    Text('3. Place it in: android/app/'),
                    Text('4. Restart the app'),
                  ],
                ),
              ),
              const SizedBox(height: 25),
              Text('Original Error:', style: TextStyle(fontSize: 10, color: Colors.grey[400])),
              Text(widget.initializationError ?? 'Unknown Error', 
                style: const TextStyle(fontSize: 10, color: Colors.red, fontStyle: FontStyle.italic)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () { /* Possible retry logic */ },
                child: const Text('RETRY CONNECTION'),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        border: Border(bottom: BorderSide(color: Colors.grey[400]!, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.monitor, size: 20, color: Colors.blueGrey),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text(
                    'LIVE POS TERMINAL',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'SYNC STATUS: REAL-TIME ONLINE  |  ID: $_sessionId',
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBillingArea(List<CartItem> cartItems) {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Table(
            border: TableBorder.all(color: Colors.grey[400]!, width: 0.5),
            columnWidths: const {
              0: FlexColumnWidth(1),
              1: FlexColumnWidth(4),
              2: FlexColumnWidth(1),
              3: FlexColumnWidth(1),
              4: FlexColumnWidth(1.2),
              5: FixedColumnWidth(40),
            },
            children: [
              TableRow(
                decoration: BoxDecoration(color: Colors.blueGrey[50]),
                children: [
                  _cell('CODE', isHeader: true),
                  _cell('DESCRIPTION', isHeader: true),
                  _cell('QTY', isHeader: true),
                  _cell('EXPIRY DATE', isHeader: true),
                  _cell('AMOUNT', isHeader: true),
                  const SizedBox(),
                ],
              ),
            ],
          ),
          Expanded(
            child: cartItems.isEmpty
                ? const Center(child: Text('WAITING FOR SCANNER INPUT...', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)))
                : ListView.builder(
                    itemCount: cartItems.length,
                    itemBuilder: (context, index) {
                      final item = cartItems[index];
                      return InkWell(
                        onTap: () => _showEditItemDialog(index),
                        child: Table(
                          border: TableBorder(
                            bottom: BorderSide(color: Colors.grey[300]!, width: 0.5),
                            verticalInside: BorderSide(color: Colors.grey[300]!, width: 0.5),
                          ),
                          columnWidths: const {
                            0: FlexColumnWidth(1),
                            1: FlexColumnWidth(4),
                            2: FlexColumnWidth(1),
                            3: FlexColumnWidth(1),
                            4: FlexColumnWidth(1.2),
                            5: FixedColumnWidth(40),
                          },
                          children: [
                            TableRow(
                              children: [
                                _cell(item.id),
                                _cell(item.name.toUpperCase()),
                                _cell(item.qty.toString()),
                                _cell(item.expiryDate),
                                _cell(item.price.toStringAsFixed(2), isBold: true),
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.grey, size: 14),
                                  onPressed: () => _removeItem(index),
                                  padding: EdgeInsets.zero,
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cell(String text, {bool isHeader = false, bool isBold = false}) {
    return Container(
      height: 40,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: (isHeader || isBold) ? FontWeight.bold : FontWeight.normal,
          fontSize: isHeader ? 11 : 13,
          color: isHeader ? Colors.blueGrey[900] : Colors.black87,
          fontFamily: isHeader ? null : 'monospace',
        ),
      ),
    );
  }

  Widget _buildSummaryPanel(double subTotal, double total, List<CartItem> cartItems) {
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF263238)),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('BILL SUMMARY', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          const SizedBox(height: 25),
          TextField(
            controller: _phoneController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'CUSTOMER PHONE (PRE-SCAN)',
              labelStyle: TextStyle(color: Colors.white54, fontSize: 10),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
            ),
          ),
          const SizedBox(height: 30),
          _summaryRow('ITEMS COUNT', cartItems.length.toString()),
          _summaryRow('TAXABLE AMT', '₹${subTotal.toStringAsFixed(2)}'),
          _summaryRow('TAX / GST', '₹0.00'),
          const Divider(color: Colors.white10, height: 40),
          _summaryRow('TOTAL BILL', '₹${total.toStringAsFixed(2)}', isTotal: true),
          const SizedBox(height: 40),
          ElevatedButton.icon(
            onPressed: _showScannerDialog,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('SCAN ITEM'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange[900],
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
              shape: const RoundedRectangleBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => _showCheckoutDialog(cartItems, total),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[700],
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
              shape: const RoundedRectangleBorder(),
            ),
            child: const Text('CHECKOUT [F12]', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _clearCart,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Colors.white10),
              minimumSize: const Size(double.infinity, 50),
              shape: const RoundedRectangleBorder(),
            ),
            child: const Text('CLEAR SESSION'),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: isTotal ? Colors.white : Colors.white60, fontSize: isTotal ? 16 : 12, fontWeight: isTotal ? FontWeight.bold : null)),
          Text(value, style: TextStyle(color: Colors.white, fontSize: isTotal ? 22 : 14, fontWeight: isTotal ? FontWeight.bold : null)),
        ],
      ),
    );
  }

  Widget _buildBottomBar(double total) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(top: BorderSide(color: Colors.grey[300]!, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('NET PAYABLE:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.blueGrey)),
          Text(
            '₹ ${total.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.black, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
