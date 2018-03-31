import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:simple_permissions/simple_permissions.dart';
import 'package:image_picker/image_picker.dart';


void requestAndSetPermissions() async {
  bool res = await SimplePermissions.checkPermission(Permission.Camera);
  if (!res) await SimplePermissions.requestPermission(Permission.Camera);
}

void main() {
  requestAndSetPermissions();
  runApp(new MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: 'Inventorio', // Doesn't seem to do anything - RC
      theme: new ThemeData(primarySwatch: Colors.blue,),
      home: new MyHomePage(title: 'Inventorio'), // This sets the header - RC
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;
  MyHomePage({Key key, this.title}) : super(key: key);
  @override _MyHomePageState createState() => new _MyHomePageState();
}

class InventoryItem {
  static final uuidGenerator = new Uuid();
  final String uuid = uuidGenerator.v4();
  var label, expirationDate, barCode, image;
  InventoryItem({this.label, this.expirationDate, this.barCode, this.image});
}

class InventoryListItem extends StatelessWidget {
  final InventoryItem inventoryItem;
  InventoryListItem(this.inventoryItem): super();
  @override
  Widget build(BuildContext context) {
    return new ListTile(
      leading: new CircleAvatar(backgroundImage: new FileImage(inventoryItem.image),),
      title: new Text(inventoryItem.label),
      subtitle: new Text(inventoryItem.uuid),
      trailing: new Text(inventoryItem.expirationDate),
    );
  }
}

class _MyHomePageState extends State<MyHomePage> {
  DateTime lastPickedDate = new DateTime.now();
  final List<InventoryItem> inventoryItems = new List();

  void _addInventoryItem(BuildContext context) async {
    var expirationDate = await showDatePicker(context: context,
        initialDate: lastPickedDate,
        firstDate: lastPickedDate,
        lastDate: lastPickedDate.add(const Duration(days: 365*5)));
    if (expirationDate != null) {
      var image = await ImagePicker.pickImage(source: ImageSource.camera);
      if (image != null) setState(() {
        inventoryItems.add(new InventoryItem(
          label: 'Optional Label ${inventoryItems.length}',
          expirationDate: expirationDate.toIso8601String().substring(0, 10),
          image: image,
        ));
      });
    }
  }

  void _removeInventoryItem(InventoryItem item) async {
    setState(() => inventoryItems.remove(item));
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called.
    return new Scaffold(
      appBar: new AppBar(title: new Text(widget.title),),
      body: new ListView.builder(
        itemCount: inventoryItems.length,
        itemBuilder: (BuildContext context, int index) =>
          new Dismissible(
            key: new ObjectKey(inventoryItems[index].uuid),
            child: new InventoryListItem(inventoryItems[index]),
            onDismissed: (direction) => _removeInventoryItem(inventoryItems[index]),
          ),
      ),
      floatingActionButton: new Builder(
        builder: (BuildContext context) {
          return new FloatingActionButton(
            onPressed: () { _addInventoryItem(context); },
            tooltip: 'Add new inventory item',
            child: new Icon(Icons.add),
          );
        }
      ),
    );
  }
}