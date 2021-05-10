import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  await hetu.eval(r'''

    var i = 42
    fun getID() {
      i = 41
      print('i: ${i}')
      var j = i
      print('j: ${j}')

    }

    ''', codeType: CodeType.module, invokeFunc: 'getID');
}
