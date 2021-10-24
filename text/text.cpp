
#include<iostream>
#include<algorithm>
#include<string>
#include<vector>
#include <chrono>
#include <mutex>
#include <sstream>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <regex>
#include <future>
#include <fstream>
using namespace std;


#define HOSTNAME "http://short-url/"

// Function to generate a short url from integer ID
string idToShortURL(long unsigned n)
{
    // Map to store 62 possible characters
    char map[] = "abcdefghijklmnopqrstuvwxyzABCDEF"
                 "GHIJKLMNOPQRSTUVWXYZ0123456789";
 
    string shorturl;
 
    // Convert given integer id to a base 62 number
    while (n)
    {
        // use above map to store actual character
        // in short url
        shorturl.push_back(map[n%62]);
        n = n/62;
    }
 
    // Reverse shortURL to complete base conversion
    reverse(shorturl.begin(), shorturl.end());
 
    return shorturl;
}
 
// Function to get integer ID back from a short url
long unsigned shortURLtoID(string shortURL)
{
    long unsigned id = 0; // initialize result
 
    // A simple base conversion logic
    for (int i=0; i < shortURL.length(); i++)
    {
        if ('a' <= shortURL[i] && shortURL[i] <= 'z')
          id = id*62 + shortURL[i] - 'a';
        if ('A' <= shortURL[i] && shortURL[i] <= 'Z')
          id = id*62 + shortURL[i] - 'A' + 26;
        if ('0' <= shortURL[i] && shortURL[i] <= '9')
          id = id*62 + shortURL[i] - '0' + 52;
    }
    return id;
}


string shortURL(string longURL)
{
     long unsigned ID = shortURLtoID(longURL);
	 string shortURL = HOSTNAME + idToShortURL(ID);
	 
	 //cout<<shortURL<<endl;
	 
	 return shortURL;
	 //TO DO: save to the memcached or DB
	 //save (ID, longURL, shortURL)
}


string processText(int64_t req_id,
    const std::string &text)
{
	//check user mentioned
  std::vector<std::string> user_mentions;
  std::smatch m;
  std::regex e("@[a-zA-Z0-9-_]+");
  auto s = text;
  while (std::regex_search(s, m, e)){
    auto user_mention = m.str();
    user_mention = user_mention.substr(1, user_mention.length());
    user_mentions.emplace_back(user_mention);
    s = m.suffix().str();
  }
  
	//TO DO: add user mentioned in the database
  for(unsigned i=0; i<user_mentions.size(); i++)
	cout<<user_mentions[i]<<endl;


	//check urls
  std::vector<std::string> urls;
  e = "(http://|https://)([a-zA-Z0-9_!~*'().&=+$%-]+)";
  s = text;
  while (std::regex_search(s, m, e)){
    auto url = m.str();
    urls.emplace_back(url);
    s = m.suffix().str();
  }
  
  std::vector<std::string> shortened_urls ;
  for(unsigned i=0; i<urls.size(); i++)
	shortened_urls.push_back(shortURL(urls[i]));



  std::string updated_text;
  if (!urls.empty()) {
    s = text;
    int idx = 0;
    while (std::regex_search(s, m, e)){
      auto url = m.str();
      urls.emplace_back(url);
      updated_text += m.prefix().str() + shortened_urls[idx];
      s = m.suffix().str();
      idx++;
    }
  } else {
    updated_text = text;
  }

	return updated_text;
  
}


int main(int argc, char *argv[]) {

	if(argc < 3) {
        printf("You must provide the number of lines and csv file\n");
        exit(0);
    }
	
	int num_lines = 0;
	int lines = 0;
	    fstream postfile;


	 std::string fstream(argv[1]);
	num_lines = atoi(argv[2]);

  
   postfile.open(argv[1],ios::in); 
   if (postfile.is_open()){  
      string tp;
      while(getline(postfile, tp) && lines < num_lines){ 
		if(tp == "")
		  continue;
		
		cout << "post id text: " << lines <<endl;
		cout << "original text: " << tp <<endl;
		cout << "processed text: " << processText( lines, tp ) <<endl<<endl;
		 lines++;
      }
      postfile.close(); 
   }

	return 0;
}

