test('annotations', normal, run_command, ['$MAKE -s --no-print-directory annotations'])
test('parseTree',   normal, run_command, ['$MAKE -s --no-print-directory parseTree'])
test('comments',    normal, run_command, ['$MAKE -s --no-print-directory comments'])

