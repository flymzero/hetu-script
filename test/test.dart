import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  await hetu.eval(r'''
    fun getID(expr) {
      when(expr) {
        0: return '0'
        1: return '1'
      }
      return ''
    }

    print(getID(5 - 4))

  
    ''', codeType: CodeType.script);
}
