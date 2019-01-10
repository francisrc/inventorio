import 'dart:io';

import 'package:logging/logging.dart';
import 'package:flutter_simple_dependency_injection/injector.dart';
import 'package:rxdart/rxdart.dart';
import 'package:inventorio/bloc/repository_bloc.dart';
import 'package:inventorio/data/definitions.dart';

enum Act {
  SignIn,
  SignOut,
  AddInventory,
  ChangeInventory,
  UpdateInventory,
  UnsubscribeInventory,
  RemoveItem,
  AddUpdateItem,
  AddUpdateProduct
}

class Action {
  final Act act;
  final dynamic payload;
  Action(this.act, this.payload);
}

class InventoryBloc {
  final _log = Logger('InventoryBloc');
  final _repo = Injector.getInjector().get<RepositoryBloc>();

  final _actions = BehaviorSubject<Action>();
  Function(Action) get actionSink => _actions.sink.add;

  final _selected = BehaviorSubject<List<InventoryItem>>();
  Function(List<InventoryItem>) get selectedSink => _selected.sink.add;
  Observable<List<InventoryItem>> get selectedStream => _selected.stream;

  final _details = BehaviorSubject<List<InventoryDetails>>();
  Function(List<InventoryDetails>) get detailSink => _details.sink.add;

  InventoryBloc() {
    _repo.userUpdateStream
      .listen((userAccount) async {
        if (userAccount != null) {
          _populateSelectedItems(userAccount);
        }
      });

    _actions.listen((action) {
      switch (action.act) {
        case Act.SignIn: _repo.signIn(); break;
        case Act.SignOut: _cleanUp(); _repo.signOut(); break;
        case Act.ChangeInventory: _repo.changeCurrentInventory(action.payload); break;
        case Act.RemoveItem: _repo.removeItem(action.payload); break;
        case Act.AddUpdateItem: _repo.updateItem(action.payload); break;
        case Act.AddUpdateProduct: _repo.updateProduct(action.payload); break;
        case Act.UnsubscribeInventory: _repo.unsubscribeFromInventory(action.payload); break;
        case Act.UpdateInventory: _repo.updateInventory(action.payload); break;
        case Act.AddInventory: _repo.addInventory(action.payload); break;
        default: _log.warning('Action ${action.payload} NOT IMPLEMENTED'); break;
      }
    });

    _repo.signIn();
  }

  void _populateSelectedItems(UserAccount userAccount) {
    _repo.getItemListObservable(userAccount.currentInventoryId)
      .debounce(Duration(milliseconds: 300))
      .listen((data) {
        data.sort();
        selectedSink(data);
      });
  }

  void _cleanUp() {
    selectedSink([]);
  }

  void dispose() async {
    _actions.close();
    _selected.close();
    _details.close();
  }
}