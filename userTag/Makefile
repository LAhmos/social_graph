TARGET := userTag

$(TARGET): userTag.cpp
	g++ -fopenmp -std=c++11 -o $@ $^

run: $(TARGET)
	./$(TARGET)

clean: 
	rm -f $(TARGET) *.o