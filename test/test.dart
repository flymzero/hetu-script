import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  await hetu.eval(r'''
      var items = [7,6,5,4,3]
        fun getNum(j: num) {
          for (var i = 0; i < items.length; ++i) {
            if (items[i] == j) {
              return i
            }
          }
          return -1
        }
      fun main() {
        for (var m = 0; m < 6; ++m) {
          var k = getNum(m)
          if (k != -1) {
            print( '${m}: k is ${k}' )
          } else {
            print( '${m}: k is -1 ' )
          }
        }
        print('where are you?')
      }
    ''', codeType: CodeType.module, invokeFunc: 'main');
}
