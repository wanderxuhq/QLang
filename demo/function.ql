abs(a){
	print("123\n")
	if(a<0){
		print("<0\n")
		return -a
	}
	else{
		print(">0\n")
		return a
	}
}

main(){
	abs(1)
	print("main")
}