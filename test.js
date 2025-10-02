process.stdin.setRawMode(true);
process.stdin.on('data', d => {
	const b = Array.from(d);
	// process.stdout.write(b.map(x => String.fromCharCode(x)).join(''));
	console.log(b.map(x =>
		[String.fromCharCode(x), x, x.toString(2).padStart(8, '0')]));
	if (b[0] == 3) {
		process.exit();
	}
});
