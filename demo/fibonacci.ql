f(n){
	if(n==1 || n==2){
		return 1
	}
	else{
		result = f(n-1) + f(n-2)
		//print(result+"\n")
		return result
	}
}
main(){
	k = f(3)
	print(k)
}