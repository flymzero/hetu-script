import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  final a = await hetu.eval(r'''
    class Column{
      var items

      construct({items}) {
        this.items = items
      }
    }

    var i = 42
    fun getID() {
      var j = i
      i = 1
      print('j: ${j}')

      var items = ['child']

      var col = Column(items: items)

      return(col)

    }

    ''', codeType: CodeType.module, invokeFunc: 'getID');

  print(a);
}
