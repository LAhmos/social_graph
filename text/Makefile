TARGET := text

$(TARGET): text.cpp
	g++ -fopenmp -g -std=c++17 -o $@ $^

run: $(TARGET)
	./$(TARGET)

clean: 
	rm -f $(TARGET) *.o
