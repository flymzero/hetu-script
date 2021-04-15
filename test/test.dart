import 'package:hetu_script/hetu_script.dart';

void main() async {
  var hetu = Hetu();
  await hetu.init();
  await hetu.eval(r'''
      fun escape() {
          print('a\nb')
      }
      ''', invokeFunc: 'escape');
}
