
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:inventorio/bloc/scheduling_bloc.dart';
import 'package:logging/logging.dart';
import 'package:flutter_simple_dependency_injection/injector.dart';
import 'package:inventorio/bloc/inventory_bloc.dart';
import 'package:inventorio/bloc/repository_bloc.dart';
import 'package:inventorio/pages/listings_page.dart';

class InventoryApp2 extends StatefulWidget {
  @override _InventoryApp2State createState() => _InventoryApp2State();
}

class _InventoryApp2State extends State<InventoryApp2> {
  final _injector = Injector.getInjector();

  _InventoryApp2State() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      var logMessage = '${rec.time}: ${rec.message}';
      print('$logMessage');
    });

    _injector.map<RepositoryBloc>((_) => RepositoryBloc(), isSingleton: true);
    _injector.map<InventoryBloc>((_) => InventoryBloc(), isSingleton: true);
    _injector.map<FlutterLocalNotificationsPlugin>((_) => FlutterLocalNotificationsPlugin(), isSingleton: true);
    _injector.map<SchedulingBloc>((_) => SchedulingBloc(), isSingleton: true);
    _injector.map<NotificationDetails>((_) => NotificationDetails(
        AndroidNotificationDetails(
            'com.rcagantas.inventorio.scheduled.notifications',
            'Inventorio Expiration Notification',
            'Notification 7 and 30 days before expiry'
        ),
        IOSNotificationDetails()
    ), isSingleton: true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        fontFamily: 'OpenSans',
        primaryColor: Colors.blue.shade700,
        accentColor: Colors.blue.shade700,
      ),
      title: 'Inventorio',
      home: ListingsPage()
    );
  }

  @override
  void dispose() {
    _injector.get<InventoryBloc>().dispose();
    _injector.get<RepositoryBloc>().dispose();
    super.dispose();
  }
}