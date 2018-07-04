import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scoped_model/scoped_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:barcode_scan/barcode_scan.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:quiver/core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:flutter_native_image/flutter_native_image.dart';

part 'model.g.dart';

@JsonSerializable()
class InventoryItem extends Object with _$InventoryItemSerializerMixin {
  String uuid;
  String code;
  String expiry;

  InventoryItem({this.uuid, this.code, this.expiry});
  factory InventoryItem.fromJson(Map<String, dynamic> json) => _$InventoryItemFromJson(json);

  DateTime get expiryDate => DateTime.parse(expiry.replaceAll('-', ''));
  String get year => DateFormat.y().format(expiryDate);
  String get month => DateFormat.MMM().format(expiryDate);
  String get day => DateFormat.d().format(expiryDate);
  int get daysFromToday => expiryDate.difference(DateTime.now()).inDays;
}

@JsonSerializable()
class Product extends Object with _$ProductSerializerMixin {
  String code;
  String name;
  String brand;
  String variant;
  String imageUrl;

  Product({this.code, this.name, this.brand, this.variant, this.imageUrl});
  factory Product.fromJson(Map<String, dynamic> json) => _$ProductFromJson(json);

  @override
  int get hashCode => hashObjects(toJson().values);

  @override
  bool operator ==(other) {
    return other is Product &&
      code == other.code &&
      name == other.name &&
      brand == other.brand &&
      variant == other.variant &&
      imageUrl == other.imageUrl
    ;
  }
}

@JsonSerializable()
class InventoryDetails extends Object with _$InventoryDetailsSerializerMixin {
  String uuid;
  String name;
  String createdBy;
  InventoryDetails({@required this.uuid, this.name, this.createdBy});
  factory InventoryDetails.fromJson(Map<String, dynamic> json) => _$InventoryDetailsFromJson(json);

  @override String toString() => '$name   $uuid';
}

@JsonSerializable()
class UserAccount extends Object with _$UserAccountSerializerMixin {
  List<String> knownInventories = List();
  String userId;
  String currentInventoryId;

  UserAccount(this.userId, this.currentInventoryId) {
    knownInventories.add(this.currentInventoryId);
  }

  factory UserAccount.fromJson(Map<String, dynamic> json) =>
      _$UserAccountFromJson(json);

  @override int get hashCode => hashObjects(toJson().values);

  @override
  bool operator ==(other) {
    return other is UserAccount &&
      knownInventories == other.knownInventories &&
      userId == other.userId &&
      currentInventoryId == other.currentInventoryId;
  }
}

class AppModelUtils {
  static Uuid _uuid = Uuid();
  static String generateUuid() => _uuid.v4();

  static InventoryItem buildInventoryItem(String code, DateTime expiryDate) {
    return InventoryItem(uuid: AppModelUtils.generateUuid(), code: code, expiry: expiryDate.toIso8601String().substring(0, 10));
  }

  static String capitalizeWords(String sentence) {
    if (sentence == null || sentence.trim() == '') return sentence;
    return sentence.split(' ').map((w) => '${w[0].toUpperCase()}${w.substring(1)}').join(' ').trim();
  }

  static Future<Uint8List> resizeImage(File toResize) async {
    int size = 1024;
    ImageProperties properties = await FlutterNativeImage.getImageProperties(toResize.path);

    print('Resizing image ${toResize.path}');
    File thumbnail = await FlutterNativeImage.compressImage(toResize.path, quality: 100,
        targetWidth: size,
        targetHeight: (properties.height * size / properties.width).round()
    );

    Uint8List data = thumbnail.readAsBytesSync();
    thumbnail.delete();
    return data;
  }
}

class AppModel extends Model {
  Map<String, InventoryItem> _inventoryItems = Map();
  Map<String, Product> _products = Map();
  Map<String, Product> _productsMaster = Map();
  Map<String, InventoryDetails> inventoryDetails = Map();
  String _searchFilter;

  UserAccount userAccount;

  CollectionReference _userCollection;
  CollectionReference _masterProductDictionary;
  CollectionReference _productDictionary;
  CollectionReference _inventoryItemCollection;
  GoogleSignInAccount _gUser;
  GoogleSignIn _googleSignIn;
  String _loadedAccountId;

  List<String> logMessages = List();
  void logger(String log) {
    print(log);
    log = _loadedAccountId == null? log : log.replaceAll(_loadedAccountId, '[${_loadedAccountId?.substring(0, 5)}...]');
    logMessages.add('- $log');
  }

  set filter(String f) { _searchFilter = f?.trim()?.toLowerCase(); notifyListeners(); }

  List<InventoryItem> get inventoryItems {
    List<InventoryItem> toSort = _inventoryItems.values.toList();
    toSort.sort((item1, item2) => item1.expiryDate.compareTo(item2.expiryDate));
    if (_searchFilter != null && _searchFilter != '') {
      return toSort
        .where((item) {
          Product product = getAssociatedProduct(item.code);
          return (
            (product.brand != null && product.brand.toLowerCase().contains(_searchFilter)) ||
            (product.name != null && product.name.toLowerCase().contains(_searchFilter)) ||
            (product.variant != null && product.variant.toLowerCase().contains(_searchFilter))
          );
        }).toList();
    }
    return toSort;
  }

  void _loadFromPreferences() {
    logger('Loading last known user from shared preferences.');
    SharedPreferences.getInstance().then((save) {
      String userId = save.getString('inventorio.userId');
      if (userId != null) {
        _loadedAccountId = userId;
        logger('Loading collection from preferences $userId.');
        _loadCollections(userId); // from pref
      }
    });
  }

  AppModel() {
    _ensureLogin();
  }

  void _ensureLogin() async {
    _googleSignIn = GoogleSignIn();
    logger('Listening for account changes.');
    _googleSignIn.onCurrentUserChanged.listen((account) {

      logger('Account changed.');
      if (account == null) {
        logger('User account changed but is null. Asking for sign-in.');
        _clearData();
        _googleSignIn.signIn();
        return;
      }

      _onLogin(account);
    });

    GoogleSignInAccount account = _googleSignIn.currentUser;
    if (account == null) {
      logger('Attempting silent sign-in.');
      account = await _googleSignIn.signInSilently().catchError((error) {
        logger('Error on silent sign-in: $error');
      });
    }

    if (account == null) {
      logger('Attempting proper sign-in.');
      account = await _googleSignIn.signIn().catchError((error) {
        logger('Error on sign-in: $error');
      }).timeout(Duration(seconds: 2), onTimeout: () {
        logger('Timeout on proper sign-in');
      });
    }

    if (account == null) _loadFromPreferences();
    logger('Logged in as: ${account?.id}');
  }

  void _onLogin(GoogleSignInAccount account) {
    if (account == null) return;
    _loadedAccountId = account.id;
    logger('Google sign-in account id: ${account.id}');
    _gUser = account;
    _gUser.authentication.then((auth) {
      logger('Firebase sign-in with Google: ${account.id}');
      FirebaseAuth.instance.signInWithGoogle(idToken: auth.idToken, accessToken: auth.accessToken);
    });

    SharedPreferences.getInstance().then((save) => save.setString('inventorio.userId', account.id));
    logger('Loading collection from Google Sign-in ${account.id}');
    _loadCollections(account.id); // for user change
  }

  void _clearData() {
    logger('Clearing data.');
    _gUser = null;
    _inventoryItems.clear();
    _products.clear();
    _productsMaster.clear();
    _inventoryItems.clear();
    _userCollection = null;
    _masterProductDictionary = null;
    _productDictionary = null;
    _inventoryItemCollection = null;

    userAccount = null;
    notifyListeners();
  }

  void signIn() { _googleSignIn.signIn(); }
  void signOut() { _googleSignIn.signOut(); }

  bool get isSignedIn => _gUser != null;
  String get userDisplayName => _gUser?.displayName ?? '';
  String get userImageUrl => _gUser?.photoUrl ?? '';
  InventoryDetails get currentInventory => inventoryDetails[userAccount?.currentInventoryId ?? 0] ?? null;

  void _createNewUserAccount(String userId) {
    logger('Attempting to create user account for $userId');
    UserAccount userAccount = UserAccount(userId, AppModelUtils.generateUuid());

    Firestore.instance.collection('inventory').document(userAccount.currentInventoryId).setData(InventoryDetails(
      uuid: userAccount.currentInventoryId,
      name: 'Inventory',
      createdBy: userAccount.userId,
    ).toJson());

    _userCollection.document(userId).setData(userAccount.toJson());
  }

  void _loadCollections(String userId) {
    logger('Loading inventory collection for $userId');
    _userCollection = Firestore.instance.collection('users');
    _userCollection.document(userId).snapshots().listen((userDoc) {
      if (!userDoc.exists) {
        _createNewUserAccount(userId);
        return;
      }
      userAccount = UserAccount.fromJson(userDoc.data);
      logger('Retrieving inventory account ${userAccount.userId}');
      _loadData(userAccount);
    });
  }

  void _loadData(UserAccount userAccount) {
    _masterProductDictionary = Firestore.instance.collection('productDictionary');
    _productDictionary = Firestore.instance.collection('inventory').document(userAccount.currentInventoryId).collection('productDictionary');
    _inventoryItemCollection = Firestore.instance.collection('inventory').document(userAccount.currentInventoryId).collection('inventoryItems');
    _inventoryItemCollection.snapshots().listen((snap) {
      _inventoryItems.clear();
      if (snap.documents.isEmpty) notifyListeners();
      snap.documents.forEach((doc) {
        InventoryItem item = InventoryItem.fromJson(doc.data);
        _inventoryItems[doc.documentID] = item;
        notifyListeners();
        _syncProductCode(item.code);
      });
    });

    userAccount.knownInventories.forEach((inventoryId) {
      Firestore.instance.collection('inventory').document(inventoryId).snapshots().listen((doc) {
        if (doc.exists && userAccount.knownInventories.contains(inventoryId)) {
          inventoryDetails[inventoryId] = InventoryDetails.fromJson(doc.data);
          notifyListeners();
        }
      });
    });
  }

  void _syncProduct(DocumentSnapshot doc, Map productMap) {
    if (doc.exists) {
      Product product = Product.fromJson(doc.data);
      productMap[product.code] = product;
      notifyListeners();
    }
  }

  void _syncProductCode(String code) {
    if (getAssociatedProduct(code) != null) return; // avoid multiple sync
    _productDictionary.document(code).snapshots().listen((doc) => _syncProduct(doc, _products));
    _masterProductDictionary.document(code).snapshots().listen((doc) => _syncProduct(doc, _productsMaster));
  }

  Future<bool> isProductIdentified(String code) async {
    logger('Checking remote dictionary for $code');
    var doc = await _productDictionary.document(code).get();
    if (doc.exists) { _syncProduct(doc, _products); return true; }

    logger('Checking remote master dictionary for $code');
    var masterDoc = await _masterProductDictionary.document(code).get();
    if (masterDoc.exists) { _syncProduct(masterDoc, _productsMaster); return true; }

    logger('$code not identified');
    return false;
  }

  void removeItem(String uuid) {
    logger('Trying to delete item $uuid');
    _inventoryItemCollection.document(uuid).delete();
  }

  void addItem(InventoryItem item) {
    logger('Trying to add item ${item.toJson()}');
    _inventoryItemCollection.document(item.uuid).setData(item.toJson());
  }

  Future<Product> _uploadProductImage(Product product, Uint8List imageDataToUpload) async {
    if (imageDataToUpload == null || imageDataToUpload.isEmpty) return product;

    String uuid = AppModelUtils.generateUuid();
    String fileName = '${product.code}_$uuid.jpg';
    product.imageUrl = await _uploadDataToStorage(imageDataToUpload, 'images', fileName);

    return product;
  }

  Future<String> _uploadDataToStorage(Uint8List data, String folder, String fileName) async {
    StorageReference storage = FirebaseStorage.instance.ref().child(folder).child(fileName);
    StorageUploadTask uploadTask = storage.putData(data);
    UploadTaskSnapshot uploadSnap = await uploadTask.future;
    String url = uploadSnap.downloadUrl.toString();
    logger('Uploaded $fileName to url');
    return url;
  }

  void _uploadProduct(Product product) {
    logger('Trying to set product ${product.code} with ${product.toJson()}');
    _productDictionary.document(product.code).setData(product.toJson());
    _masterProductDictionary.document(product.code).setData(product.toJson());
  }

  void addProduct(Product product) {
    _syncProductCode(product.code);
    _productsMaster[product.code] = product;
    notifyListeners(); // temporarily set to trigger updates on UI while we wait for server.

    _uploadProduct(product); // persist immediately so we don't lose the data.
  }

  void addProductImage(Product product, Uint8List imageDataToUpload) {
    _uploadProductImage(product, imageDataToUpload).then((product) { _uploadProduct(product); }); // again but with image url
  }

  Product getAssociatedProduct(String code) {
    return _products.containsKey(code)? _products[code] : _productsMaster[code];
  }

  Future<bool> sureDialog(BuildContext context, String question, String yes, String no) async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(question, style: TextStyle(fontFamily: 'Montserrat', fontSize: 18.0),),
          actions: <Widget>[
            FlatButton(
              child: Text(yes, style: TextStyle(fontFamily: 'Montserrat', fontSize: 18.0),),
              onPressed: () { Navigator.of(context).pop(true); },
            ),
            FlatButton(
              color: Theme.of(context).primaryColor,
              child: Text(no, style: TextStyle(fontFamily: 'Montserrat', fontSize: 18.0, color: Colors.white),),
              onPressed: () { Navigator.of(context).pop(false); },
            ),
          ],
        );
      }
    );
  }

  void addInventory(InventoryDetails inventory) {
    if (userAccount == null || inventory == null) return;
    if (!userAccount.knownInventories.contains(inventory.uuid)) {
      userAccount.knownInventories.add(inventory.uuid);
    }
    userAccount.currentInventoryId = inventory.uuid;
    _userCollection.document(userAccount.userId).setData(userAccount.toJson());
    _loadData(userAccount);

    inventory.createdBy = userAccount.userId;
    Firestore.instance.collection('inventory').document(inventory.uuid).setData(inventory.toJson());
    logger('Setting inventory: ${inventory.uuid}');
  }

  void changeCurrentInventory(String code) {
    if (userAccount == null || code == null) return;
    if (!userAccount.knownInventories.contains(code)) return;
    userAccount.currentInventoryId = code;
    _userCollection.document(userAccount.userId).setData(userAccount.toJson());
  }

  void unsubscribeInventory(String code) {
    if (userAccount == null || code == null) return;
    if (userAccount.knownInventories.length == 1) return;
    userAccount.knownInventories.remove(code);
    userAccount.currentInventoryId = userAccount.knownInventories[0];
    _userCollection.document(userAccount.userId).setData(userAccount.toJson());
    logger('Unsubscribing ${userAccount.userId} from inventory $code');
  }

  Future<String> scanInventory() async {
    if (userAccount == null) return null;
    String code = await BarcodeScanner.scan();
    if (!userAccount.knownInventories.contains(code)) userAccount.knownInventories.add(code);
    userAccount.currentInventoryId = code;
    logger('Scanned inventory code $code');
    _userCollection.document(userAccount.userId).setData(userAccount.toJson());
    return code;
  }
}