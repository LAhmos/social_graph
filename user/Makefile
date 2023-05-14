TARGET := user

$(TARGET): user.cpp
	g++ -fopenmp -std=c++11 -o $@ $^

run: $(TARGET)
	./$(TARGET)

clean: 
	rm -f $(TARGET) *.o