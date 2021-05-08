import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  await hetu.eval(r'''
    var i = 42
    print(i)
    var j = i
    i = 0

    print(j)
    ''', codeType: CodeType.script);
}
