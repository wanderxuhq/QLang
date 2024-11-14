let k=10
let l=1
while(l<=k){
	let i=1
	while(i<=l){
		print("*")
		i=i+1
	}
	
	while(i<=2*k-1-l){
		print(" ")
		i=i+1
	}
	
	while(i<=2*k-1){
		print("*")
		i=i+1
	}
	l=l+1
	print("\n")
	i=1
}
while(l<=2*k-1){
	let i=1
	while(i<=k-(l-k)){
		print("*")
		i=i+1
	}
	while(i<=l-1){
		print(" ")
		i=i+1
	}
	while(i<=2*k-1){
		print("*")
		i=i+1
	}
	l=l+1
	print("\n")
	i=1
}