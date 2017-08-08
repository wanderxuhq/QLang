var log = console.log.bind(console);
var debug = console.debug.bind(console);
var err = console.error.bind(console);

(function(){
	
}());

var TYPE = {
	NUMBER: 1,
	STRING: 2,
}
var variables = new Map();

function core(){
	var text = document.getElementById("input").value;
	var statements = text.split("\n");
	//log(statements);
	for(statement of statements){
		//log(statement);
		execute(statement);
	}
}

var matches = [
		['(','[','{'],
		[')',']','}']
	];
	
function getMatch(tokens, i){
	var matches = [
		['(','[','{'],
		[')',']','}']
	];
	
	var operation = new Map([
		['+', function(){
			console.log('+');
		}]
	]);
	
	var matchStack = [];
	while (i < tokens.length){
		var t = tokens[i];
	var uindex = matches[0].indexOf(t);
	var oindex = matches[1].indexOf(t);
		if(uindex != -1){
			var u = matches[0][uindex];
			matchStack.push({t, i});
		} else if(oindex != -1){
			var o = matches[1][oindex];
			if(t === o){
				matchStack.pop();
			}
			if( matchStack.length === 0 ){
				return i;
			}
		}
	i++;
	}
	console.log(matchStack);
}

function calExp(tokens){
	var operation = new Map([
		['+', function(a, b){
			return a + b;
		}],
		['-', function(a, b){
			return a - b;
		}],
	]);
	
	var matchStack = [];
	var operationMark = undefined;
	var laseValue = undefined;
	var laseValueIndex = undefined;
	for(var i = 0; i < tokens.length;){
		var t = tokens[i];
	var uindex = matches[0].indexOf(t);
	//var oindex = matches[1].indexOf(t);
		if(uindex != -1){
			var u = matches[0][uindex];
			//var oindex = tokens.indexOf(matches[1][uindex]);
			var oindex = getMatch(tokens, i);
			tmpResult = calExp(tokens.slice(i + 1, oindex));
			tokens.splice(i, oindex - i + 1 , tmpResult );
			lastValue = tmpResult;
			matchStack.push({t, i});
		} 
		/*
		else if(oindex != -1){
			var o = matches[1][oindex];
			if(t === o){
				tokens = tokens.splice(matchStack[matches[0][oindex]].i,i,calExp(tokens.slice(matchStack[matches[0][oindex]].i,i)));
				matchStack.pop();
			}
		} 
		*/
		else if(operation.has(t)) {
			operationMark = t;
			i++;
		} else {
			if(operationMark != undefined){
				r = operation.get(operationMark)(getValue(laseValue),  getValue(t));
				laseValue = r;
				log(r);
				tokens.splice(laseValueIndex, i - laseValueIndex + 1 , r );
				i = laseValueIndex + 1;
				if( tokens.length === 1 )
					return r;
			}
			else{
				laseValueIndex = i;
				laseValue = t;
				i++;
			}
			
		}
	}
}

function execute(originStatement){
	var statement = originStatement.replace(/\s/g,'');
	var tokens = statement.split(/\b/);
	//log(tokens.length);
	if(tokens.length === 1)
		variables.set(tokens[0], undefined)
	else if(tokens[1] === "="){
		var variable = tokens.shift();
		variables.set(variable, undefined);
		var value = tokens;
		value.shift();
		assignment(variable, value);
	}else if(tokens[0] === "if"){
		var bool = calExp(tokens.slice(1,tokens.length));
	}else{
		var cmd = tokens.shift();
		var parameters = tokens;
		command(cmd, parameters);
	}
}

function assignment(variable, value){
	if(constVal(value) > 0){
		variables.set(variable, value);
	} else{
		var val = variables.get(value[0]);
		if (val != undefined){
			variables.set(variable, value[0]);//chain
			//variables.set(variable, val);//value
		}
	}
	debug(variable + ": " + variables.get(variable));
}

function constVal(variable){
	if(variable === undefined){
		return 0
	}
	var reg = /^(\d+)|('(\\'|\\[A-Za-z]|\\\\|[^'])+')$/
	var type = reg.exec(variable);
	if (type === null){
		return 0;
	}
	if(type[1] != undefined) {
		return TYPE.NUMBER;
	} else if(type[2] != undefined) {
		return TYPE.STRING;
	} else {
		return 0;
	}
}

function getValue(v){
	if(constVal(v) === TYPE.NUMBER){
		return parseInt(v);
	} else if(constVal(v) === TYPE.STRING){
		return v;
	}
	else {
		return getValue(variables.get(v));
	} 
}

function command(cmd, parameters){
	if(cmd === 'print'){
		debug(" result: " + calExp(parameters));
	} else if (cmd === 'add'){
		var sum = 0;
		for(var num of parameters){
			sum += parseInt(num);
		}
		debug("result: " + sum);
	}
}