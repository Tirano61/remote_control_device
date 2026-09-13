import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_device/features/device/presentation/widgets/public_id_input_formatter.dart';

String format(String input) => const PublicIdInputFormatter()
    .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: input))
    .text;

void main() {
  test('groups digits into the 384-729-142 shape', () {
    expect(format('384729142'), '384-729-142');
  });

  test('keeps partial input usable while typing', () {
    expect(format('3'), '3');
    expect(format('384'), '384');
    expect(format('3847'), '384-7');
  });

  test('drops anything that is not a digit', () {
    expect(format('384-729-142'), '384-729-142');
    expect(format('38a4 729/142'), '384-729-142');
  });

  test('never exceeds nine digits', () {
    expect(format('3847291429999'), '384-729-142');
  });
}
